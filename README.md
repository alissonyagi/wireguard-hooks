# wireguard-hooks
Linux hooks for using multiple Wireguard clients (or even a single one) without full tunneling, preserving the main route while also providing support for incoming connections over Wireguard.

Sometimes you need to accept incoming internet connections over your default route (ISP) and also over your wireguard tunnels, keeping the defaul route untouched. That's where this project fits in.

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

That's all.

## How to use

In you Wireguard's client config file (eg. `wg0.conf`), make sure to change it as below:

```ini
[Interface]
...
Table = off
PostUp = <path-to-script>/wg-hooks.sh up wg0
PreDown = <path-to-script>/wg-hooks.sh down wg0

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
> And now check you main (ISP) route:
> ```bash
> curl https://api.ipify.org
> ```

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
  #PostUp = <path-to-script>/wg-hooks.sh up wg0
  #PreDown = <path-to-script>/wg-hooks.sh down wg0
  ...
  ```
  - Now start only this Wireguard tunnel and check if it works:
  ```bash
  systemctl start wg-quick@wg0
  ping 8.8.8.8
  ```
  If ICMP is blocked, test using any other method to check if outgoing traffic is working and then check if incoming traffic works.

  If it doesn't work, Wireguard's peer is probably misconfigured.


