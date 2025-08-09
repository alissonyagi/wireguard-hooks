#!/bin/bash

OP=$1
IFACE=$2

RT_FILE="/etc/iproute2/rt_tables"
LOCK_FILE="/run/wg-hooks.lock"
TIMEOUT=15

usage() {
	echo "Usage: $0 <up|down> <interface>"
}

iface_exists() {
	local iface iface_test ret
	iface=$1
	iface_test=$(ip addr show "${iface}" 2>&1)

	return $?
}

ip_to_int() {
	local a b c d
	IFS=. read -r a b c d <<< "$1"
	echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ip_in_subnet() {
	local ip subnet subnet_ip subnet_cidr ip_int subnet_int mask
	ip=$1
	subnet=$2

	IFS=/ read -r subnet_ip subnet_cidr <<< "$subnet"
	ip_int=$(ip_to_int "$ip")
	subnet_int=$(ip_to_int "$subnet_ip")
	mask=$(( 0xFFFFFFFF << (32 - subnet_cidr) & 0xFFFFFFFF ))

	if (( (ip_int & mask) == (subnet_int & mask) )); then
		return 0
	else
		return 1
	fi
}

find_free_ip() {
	local range assigned candidate_net candidate_subnet ip1 ip2 conflict subnet iface

	range=10.200
	readarray -t assigned <<< "$(
		ip -o -f inet addr show | awk '{print $4, $2}';
		ip netns list | awk '{print $1}' | xargs -I{} ip netns exec {} ip -o -f inet addr show | awk '{print $4, $2}'
	)"

	for i in {0..255}; do
		for j in {0..252..4}; do
			candidate_net="$range.$i.$j"
			candidate_subnet="$candidate_net/30"

			ip1="$range.$i.$((j + 1))"
			ip2="$range.$i.$((j + 2))"

			conflict=0

			for line in "${assigned[@]}"; do
				read subnet iface <<< "$line"
				if ip_in_subnet "$ip1" "$subnet" || ip_in_subnet "$ip2" "$subnet"; then
					conflict=1
					break
				fi
			done

			if [[ $conflict -eq 0 ]]; then
				echo "$ip1 $ip2 $candidate_subnet"
				return 0
			fi
		done
	done

	return 1
}

if [ -z "${OP}" ] || [ -z "${IFACE}" ]; then
	usage
	exit 1
fi

if [[ ! "${OP}" =~ ^(up|down)$ ]]; then
	echo "Invalid operation specified."
	usage
	exit 1
fi

if [[ ! "${IFACE}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,13}$ ]]; then
	echo "Invalid interface name specified."
	usage
	exit 1
fi

if ! iface_exists "${IFACE}"; then
	echo "Interface does not exist."
	exit 1
fi

exec 200>"${LOCK_FILE}"
flock -x -w ${TIMEOUT} 200 || exit 1

IP=$(ip -brief addr show wg-hut0 | awk '{print $3}' | cut -d'/' -f1 | grep -v ^$)

TABLE=$(echo "rt${IFACE}" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z0-9]//g")
TABLE_EXISTS=$(awk '$1 ~ /^[0-9]+$/ { print $2 }' "${RT_FILE}" | grep "^${TABLE}$")

NETNS="ns-${IFACE}"
NETNS_EXISTS=$(ip netns list | grep "^${NETNS} ")
VETH_HOST="${IFACE}h"
VETH_NS="${IFACE}n"

if [ "${OP}" = "up" ]; then
	if [ -z "${TABLE_EXISTS}" ]; then
		USED_TABLES=$( { 
			awk '$1 ~ /^[0-9]+$/ { print $1 }' "${RT_FILE}"
			ip rule | awk '/lookup/ { print $NF }' | grep -E "^[0-9]+$"
			for i in $(seq 100 252); do
				ip route show table $i 2>/dev/null | grep -q . && echo "$i"
			done
		} | sort -n | uniq)

		TABLE_ID=$(comm -23 <(seq 100 252 | sort) <(echo "${USED_TABLES}" | sort) | sort -n | head -n1)

		if [ -z "${TABLE_ID}" ]; then
			echo "No routing table IDs left."
			exit 1
		fi

		echo "${TABLE_ID}	${TABLE}" >> "${RT_FILE}"
	fi

	USED_MARKS=$( {
		ip rule | grep -o -E "fwmark [0-9a-fx]+" | awk '{ print $2 }'
		iptables-save | grep MARK | grep -o -E "0x[0-9a-fA-F]+" | grep -v "0xffffffff" | xargs -I{} printf "%d\n" "{}"
	} | sort -n | uniq)

	MARK=$(comm -23 <(seq 100 999 | sort) <(echo "${USED_MARKS}" | sort) | sort -n | head -n1)

	ip rule add fwmark ${MARK} table ${TABLE}
	ip route add default dev ${IFACE} table ${TABLE}

	iptables -t mangle -A PREROUTING -i ${IFACE} -j CONNMARK --set-mark ${MARK}

	echo "${IP}" | xargs -I{} iptables -t mangle -A OUTPUT -s {} -j CONNMARK --restore-mark

	VETH_CONFIG=$(find_free_ip)

	if [ -z "$VETH_CONFIG" ]; then
		echo "No subnets available for netns."
		exit 1
	fi

	if [ -n "${NETNS_EXISTS}" ]; then
		echo "NetNS ${NETNS} already exists."
		exit 1
	fi

	if iface_exists "${VETH_HOST}"; then
		echo "Interface ${VETH_HOST} already exists."
		exit 1
	fi

	if iface_exists "${VETH_NS}"; then
		echo "Interface ${VETH_NS} already exists."
		exit 1
	fi

	read -r VETH_HOST_IP VETH_NS_IP VETH_SUBNET <<< "${VETH_CONFIG}"

	ip netns add ${NETNS}
	ip link add ${VETH_HOST} type veth peer name ${VETH_NS}
	ip link set ${VETH_NS} netns ${NETNS}
	ip addr add ${VETH_HOST_IP}/30 dev ${VETH_HOST}
	ip link set ${VETH_HOST} up
	ip netns exec ${NETNS} ip addr add ${VETH_NS_IP}/30 dev ${VETH_NS}
	ip netns exec ${NETNS} ip link set ${VETH_NS} up
	ip netns exec ${NETNS} ip link set lo up
	ip netns exec ${NETNS} ip route add default via ${VETH_HOST_IP}

	iptables -A FORWARD -i ${VETH_HOST} -j ACCEPT
	iptables -A FORWARD -o ${VETH_HOST} -j ACCEPT
	iptables -t nat -A POSTROUTING -s ${VETH_NS_IP} -o ${IFACE} -j MASQUERADE
	iptables -t mangle -A PREROUTING -i ${VETH_HOST} -j MARK --set-mark ${MARK}
	iptables -t mangle -A PREROUTING -i ${VETH_HOST} -j CONNMARK --save-mark
	iptables -t mangle -A POSTROUTING -s ${VETH_NS_IP} -o ${IFACE} -j CONNMARK --restore-mark

	exit 0
fi

if [ "${OP}" = "down" ]; then
	IP_REGEX=$(echo ${IP} | sed "s/ /\|/g")
	IPTABLES_RULES=$(
		iptables -S | grep -E " (${IFACE}|${VETH_HOST}|${IP_REGEX}) " | sed "s/^-A/iptables -D/";
		iptables -t nat -S | grep -E " (${IFACE}|${VETH_HOST}|${IP_REGEX}) " | sed "s/^-A/iptables -t nat -D/";
		iptables -t mangle -S | grep -E " (${IFACE}|${VETH_HOST}|${IP_REGEX}) " | sed "s/^-A/iptables -t mangle -D/"
	)

	if [ -z "${IPTABLES_RULES}" ]; then
		echo "No iptables rules found."
		exit 0
	fi

	eval "${IPTABLES_RULES}"

	MARK=$(echo "${IPTABLES_RULES}" | grep -o -E "mark 0x[0-9a-f]+" | head -n1 | cut -d" " -f2 | xargs -I{} printf "%d" "{}")

	if [ -n "${MARK}" ] && [ -n "${TABLE_EXISTS}" ]; then
		ip rule del fwmark ${MARK} table ${TABLE} 2>/dev/null
	fi

	if [ -n "${TABLE_EXISTS}" ]; then
		ip route del default dev ${IFACE} table ${TABLE} 2>/dev/null
		sed -i "/\t${TABLE}\$/d" "${RT_FILE}"
	fi

	if [ -n "${NETNS_EXISTS}" ]; then
		ip netns delete ${NETNS}
	fi

	exit 0
fi
