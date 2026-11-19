# kessel-run (connection speed test)

`kessel-run/kessel-run.sh`

How fast is the connection, and when it is slow, is it the internet line or the
network in the house - and which router? Three tests, from the menu or straight from the command line:

| Test | Measures | Against |
| ---- | -------- | ------- |
| **internet** | latency and jitter, then download and upload throughput | Cloudflare's speed endpoints (`speed.cloudflare.com`, the ones its own speed test uses), with `curl` |
| **lan** | throughput both ways | another machine, with `iperf3` |
| **path** | every hop's loss and latency, then how fast each of your routers and the target set up new connections, and a verdict naming the hop where things go wrong | a target on the internet (default `1.1.1.1`), with `mtr` (or `tracepath`) and bash |

A slow internet result next to a fast LAN result points at the line or the ISP.
A slow LAN result points at the cable, the switch or the Wi-Fi.

## Usage

```sh
kessel-run.sh                                   # menu
kessel-run.sh internet [--seconds N] [--streams N]
kessel-run.sh lan <host> [--port N] [--seconds N] [--streams N] [--no-ssh]
kessel-run.sh path [target] [--port N] [--cycles N] [--handshakes N]
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

## The path test

Why it exists: on 2026-11-18 corelia's new connections sometimes stalled for
0.2-1.7 s (Kamino item 285). Ping and a plain trace were clean all the way - a
router answers those in its fast lane. What found it was timing TCP handshakes
to each router: the Huawei mesh master stalled, the Vodafone router behind it
much less. This test does that by itself.

1. **The route**, with `mtr -n -j` (20 cycles, `--cycles`): each hop's address,
   loss, average and worst latency. Without mtr, or where mtr cannot send its
   probes, `tracepath`: one probe per hop and no loss figure.
2. **Handshakes to your routers**: every hop with a private address
   (10/8, 172.16/12, 192.168/16, and 100.64/10, where ISPs put customers behind
   carrier-grade NAT) gets 40 handshakes (`--handshakes`) on the first of ports
   80, 443, 53, 22 that accepts one. Routers on the internet refuse them, so
   they get none.
3. **Handshakes to the target** on port 443 (`--port`), the same way.
4. **The table and a verdict.**

A handshake is timed with bash's own `/dev/tcp`, between two `EPOCHREALTIME`
reads around the connect alone, in one process: nothing to install, nothing
sent but the connection itself, and a connection to meksha measures 0.4 ms. Each
is bounded by `timeout` (3 s): a lost connection request would otherwise wait
two minutes. One counts as **slow** above 100 ms or 3 x that host's median,
whichever is more, so a distant target's normal latency is not a stall.

Example (corelia, 2026-11-19, shortened):

```
  Hop  Address           Loss   Avg ms  Worst ms   Connect  median   worst    slow
    1  192.168.3.1         0%      2.9       7.6   :80         2.7  1682.1    4/40
    2  192.168.1.1         5%      4.0       5.2   :80         3.9   421.4    4/40
    3  5.158.0.3          70%      8.8       9.7
    7  1.1.1.1             0%      9.1      10.7
  →  1.1.1.1                                     :443        8.4    15.5    0/40
```

How the verdict reads it:

- **Loss that reaches the target** is traced back to the first hop from which
  every later hop loses packets too: the problem starts at that router or the
  link into it.
- **Loss at a middle hop that the target does not show** is that router
  deprioritising replies to traces: not a problem. (Hops 2 and 3 above.)
- **A router that stalls new connections** (2 or more slow handshakes, or any
  with no answer): the first one on the path is named, because every connection
  beyond it passes through it, with its ping latency beside it when that is
  fine. The target's row then says whether connections it *forwards* stall
  too: if not, it was the router's own services answering late (above: the
  Huawei stalled, 1.1.1.1 through it did not, in that run).
- **Stalls only at the target**, none on your routers: the cause is beyond
  your network.
- **A latency step that stays up** is pointed out (the longest link on the
  path), and a router that accepts none of the ports is said to be untimed.
- Otherwise: nothing wrong found.

Run it more than once: a router that stalls now and then can have a clean
minute.

## Requirements

- `curl` for the internet test.
- `mtr` (and `jq`, to read its JSON) or `tracepath`, bash 5 and `timeout` for
  the path test. mtr sends its probes without root where its `mtr-packet` has
  the `cap_net_raw` capability, as Fedora and Debian install it.
- `jq` and `iperf3` for the LAN test. A missing local `iperf3` is offered through
  Homebrew when present (no reboot on Bazzite), otherwise through
  dnf/apt/rpm-ostree.
- `gum` (framework floor).

## Menu

The LAN picker offers the last host first, then the concrete `Host` entries of
`~/.ssh/config` (wildcards skipped), then a field to type a host. For a typed
host it also asks whether to start the server over ssh. The choice is saved in
`~/.config/kessel-run/kessel-run.conf` (`LAN_HOST`, `LAN_SSH`).

The path test asks for the target, `1.1.1.1` unless you type another.

A failed test returns to the menu instead of closing it.
