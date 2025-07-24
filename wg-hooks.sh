#!/bin/bash

OP=$1
IFACE=$2

RT_FILE="/etc/iproute2/rt_tables"

usage() {
	echo "Usage: $0 <up|down> <interface>"
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

IFACE_TEST=$(ip addr show "${IFACE}" 2>&1)

if [ $? -eq 1 ]; then
	echo "Interface does not exist."
	exit 1
fi

IP=$(ip -brief addr show ${IFACE} | awk '{ $1=$2=""; sub(/^  */, ""); print }' | sed -E "s/\/[0-9]+/\/32/g"| sed "s/ /\n/")
TABLE=$(echo "rt${IFACE}" | tr "[:upper:]" "[:lower:]" | sed "s/[^a-z0-9]//g")
TABLE_EXISTS=$(awk '$1 ~ /^[0-9]+$/ { print $2 }' "${RT_FILE}" | grep "^${TABLE}$")

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

	exit 0
fi

if [ "${OP}" = "down" ]; then
	IP_REGEX=$(echo ${IP} | sed "s/ /\|/g")

	IPTABLES_RULES=$(iptables -t mangle -S | grep -E " (${IFACE}|${IP_REGEX}) ")

	if [ -z "${IPTABLES_RULES}" ]; then
		echo "No iptables rules found."
		exit 1
	fi

	IPTABLES_CLEANUP=$(iptables -t mangle -S | grep -E " (${IFACE}|${IP_REGEX}) " | sed "s/^-A/iptables -t mangle -D/")
	eval "${IPTABLES_CLEANUP}"

	MARK=$(echo "${IPTABLES_RULES}" | grep -o -E "mark 0x[0-9a-f]+" | head -n1 | cut -d" " -f2 | xargs -I{} printf "%d" "{}")

	if [ -n "${MARK}" ] && [ -n "${TABLE_EXISTS}" ]; then
		ip rule del fwmark ${MARK} table ${TABLE} 2>/dev/null
	fi

	if [ -n "${TABLE_EXISTS}" ]; then
		ip route del default dev ${IFACE} table ${TABLE} 2>/dev/null
		sed -i "/\t${TABLE}\$/d" "${RT_FILE}"
	fi

	exit 0
fi
