# kessel-run (connection speed test)

`kessel-run/kessel-run.sh`

How fast is the connection, and when it is slow, is it the internet line or the
network in the house? Two tests, from the menu or straight from the command line:

| Test | Measures | Against |
| ---- | -------- | ------- |
| **internet** | latency and jitter, then download and upload throughput | Cloudflare's speed endpoints (`speed.cloudflare.com`, the ones its own speed test uses), with `curl` |
| **lan** | throughput both ways | another machine, with `iperf3` |

A slow internet result next to a fast LAN result points at the line or the ISP.
A slow LAN result points at the cable, the switch or the Wi-Fi.

## Usage

```sh
kessel-run.sh                                   # menu
kessel-run.sh internet [--seconds N] [--streams N]
kessel-run.sh lan <host> [--port N] [--seconds N] [--streams N] [--no-ssh]
```

Defaults: 10 seconds per direction, 4 parallel streams, port 5201.

Results go to stdout, one `Label  value` line each. Progress and errors go to
stderr, so the results can be logged from cron:

```sh
kessel-run.sh internet >> ~/speed.log
```

Example (internet):

```
  Server     Cloudflare LIS
  You        203.0.113.7 (AS12353)
  Latency    7.9 ms (min 7.5, max 9.1, jitter 0.6 ms, 20 handshakes)
  Download   493.5 Mbit/s (370.8 MB in 6.01 s)
  Upload     119.5 Mbit/s (90.1 MB in 6.03 s)
```

`Server` is the Cloudflare data centre that answered, as an airport code. It is
anycast, so it can change between runs.

## How the internet test measures

- **Latency** is the TCP handshake time of 20 fresh connections: curl's
  `time_connect` minus its DNS time. That is one round trip, without the server
  processing time a full HTTP request would add. The report shows the median, the
  minimum and the maximum.
- **Jitter** is the mean difference between consecutive samples. One slow
  handshake (a lost SYN is resent after a second) raises it on its own, which is
  why the maximum is shown next to it.
- **Throughput** is the bytes moved by N parallel streams divided by the
  wall-clock time. Each stream repeats requests until the time is up: 50 MB
  downloads, the most Cloudflare accepts (anything larger gets HTTP 403), and
  25 MB uploads. Every request is capped by `curl --max-time` at the time left,
  so a slow line does not overrun, and the partial bytes of the last request
  still count.
- It uses several streams because one TCP connection rarely fills a fast line.
  Each request opens a new connection, so the result comes out a little under
  what one long transfer would reach.
- Uploads are sent without `Expect: 100-continue`. Otherwise curl waits up to a
  second for the server's go-ahead before every body.
- A refused request (HTTP 403, or HTTP 429 when Cloudflare rate-limits the
  address) or a failed connection stops the test with that reason. It prints no
  number, and it does not retry in a loop.

## The LAN test

Over ssh (the default), for each direction it:

1. checks that `iperf3` is installed on the other machine. If it is not, the
   script stops and says how to install it. **It never installs anything on
   another machine**: for a server managed by Ansible, the package belongs in
   the playbook.
2. starts a one-shot server there, bounded by `timeout`:
   `ssh -f <host> 'timeout <seconds+30> iperf3 -s -1 -p <port>'`. It serves one
   test and exits, so nothing is left listening.
3. runs the client against the alias's real address. The address comes from
   `ssh -G <host>`, because iperf3 cannot resolve an ssh alias. While the server
   is still starting, a refused connection is retried for up to 5 seconds.

Upload is this machine → host; download is `-R`, host → this machine. Both
report what the receiver got (`sum_received`), not what the sender pushed into its
buffers. On Linux, the speed of the local interface that reaches the host is
shown too, so 940 Mbit/s on a `1000 Mbit/s` link reads as full speed.

`--no-ssh` tests against a host already running `iperf3 -s`, such as a NAS or
router. A refused connection there is reported right away (firewall, or no
server) and not retried.

The ssh connection uses `BatchMode`: the host needs key-based login, because a
password prompt would hang the test.

## Requirements

- `curl` for the internet test.
- `jq` and `iperf3` for the LAN test. A missing local `iperf3` is offered through
  Homebrew when present (no reboot on Bazzite), otherwise through
  dnf/apt/rpm-ostree.
- `gum` (framework floor).

## Menu

The LAN picker offers the last host first, then the concrete `Host` entries of
`~/.ssh/config` (wildcards skipped), then a field to type a host. For a typed
host it also asks whether to start the server over ssh. The choice is saved in
`~/.config/kessel-run/kessel-run.conf` (`LAN_HOST`, `LAN_SSH`).

A failed test returns to the menu instead of closing it.
