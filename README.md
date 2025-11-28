# wireguard-hooks
Linux hooks for using multiple Wireguard clients (or even a single one) without full tunneling, preserving the main route while also providing support for incoming connections over Wireguard.

Sometimes you need to accept incoming internet connections over your default route (ISP) and also over your wireguard tunnels, keeping the defaul route untouched. That's where this project fits in.

NetNS - net namespace - support added. Simple and effective isolation for services or clients.

**Currently works only over IPv4 (will add IPv6 if someone needs).**

## Installation
All setup must be done using root (or via sudo).

1. Clone git repository
```bash
git clone https://github.com/alissonyagi/wireguard-hooks.git
```
2. Adjust script permission and ownership
```bash
chown root wireguard-hooks/wg-hooks.sh
chmod u+x wireguard-hooks/wg-hooks.sh
```
3. Run `wg-hooks.sh` without arguments to see usage tips:
```bash
./wireguard-hooks/wg-hooks.sh
```

That's all.

## How to use

In you Wireguard's client config file (eg. `wg0.conf`), make sure to change it as below:

```ini
[Interface]
...
Table = off
PostUp = <path-to-script>/wg-hooks.sh wg0 dns 8.8.8.8 up
PreDown = <path-to-script>/wg-hooks.sh wg0 down

[Peer]
...
# Adjust below if you need to filter incoming connections or leave it like this to accept from any
AllowedIPs = 0.0.0.0/0
```

Now just start (or restart) your Wireguard client to see the magic happening (or not).

```bash
systemctl start wg-quick@wg0
```

> [!TIP]
> If your outgoing traffic is allowed, try the following to get your external IP:
> ```bash
> curl --interface wg0 https://api.ipify.org
> ```
> And now check you main (ISP) public IP to compare:
> ```bash
> curl https://api.ipify.org
> ```

## NetNS usage - network namespaces
Network namespace is a powerful feature of iproute2, providing isolation of network traffic.

Some clients do not support binding to specific interfaces. And this is where **netns** comes in.

This script auto creates a namespace to make it easy to connect anything over the specific tunnel.

Just run like this:
```
ip netns exec ns-<interface> <cmd>
```

Example 1 - get your public IP without specifying interface (like the examples in previous topic):
```bash
ip netns exec ns-wg0 curl https://api.ipify.org
```

Example 2 - run a NodeJS service that connects using your tunnel, without any additional setup.
```bash
ip netns exec ns-wg0 node foo_server.sh
```

> [!TIP]
> **ip netns** is a root-only command, so you must run as root (not recommended) or using a sudo wrapper like the example provided in `netns-exec`.
> If you don't know how to do it, you probably shouldn't do it.
>
> Just make it executable, place it in sudoers and run like this:
```bash
# Usage:
# sudo <path>/netns-exec <interface> <cmd>
#
# Example:
sudo netns-exec wg0 curl https://api.ipify.org
```

## Troubleshoot

1. Check your host's firewall as something might be blocking. If you're using **iptables**, start with something like:
  ```bash
  iptables -I INPUT 1 -i <wireguard-interface> -j LOG --log-prefix "WG-HOOK-INPUT: "
  iptables -I OUTPUT 1 -s <wireguard-client-address> -j LOG --log-prefix "WG-HOOK-OUTPUT: "
  dmesg | grep WG-HOOK
  ```

  Now try to access your host over your Wireguard's external IP and see if it logs something.

2. Check if your Wireguard Server is routing correctly.
  If you have local access to your machine (or another kind of out-of-band access), and network interruption is not an issue, try the following:

  - Stop all Wireguard clients
  - Change your config (`wg0.conf` as the examples above) to look like (mostly commenting rows):
  ```ini
  [Interface]
  ...
  #Table = off
  #PostUp = <path-to-script>/wg-hooks.sh wg0 up
  #PreDown = <path-to-script>/wg-hooks.sh wg0 down
  ...
  ```
  - Now start only this Wireguard tunnel and check if it works:
  ```bash
  systemctl start wg-quick@wg0
  ping 8.8.8.8
  ```
  If ICMP is blocked, test using any other method to check if outgoing traffic is working and then check if incoming traffic works.

  If it doesn't work, Wireguard's peer is probably misconfigured.


