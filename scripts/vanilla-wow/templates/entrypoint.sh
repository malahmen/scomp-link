#!/usr/bin/env bash
# Launches realmd + mangosd together, forwards SIGTERM/SIGINT to both so
# `docker stop` / pod termination shuts them down cleanly instead of being
# killed. If either process dies unexpectedly, exits non-zero so the
# container's own restart policy (docker --restart / k8s restartPolicy)
# restarts the whole thing cleanly, rather than trying to keep individual
# processes alive from inside (the original repack's run-mangosd.sh
# crash-loop script did the latter, and only covered mangosd).
set -euo pipefail

# mangosd/realmd have their config-file search path baked in at compile time
# from CMAKE_INSTALL_PREFIX (/out) — they look for /out/etc/{mangosd,realmd}.conf
# specifically, regardless of where the binaries themselves are run from.
# /app/etc/*.conf is the read-only bind/ConfigMap mount; copy from there into
# the path the binaries actually expect, and into a writable location since
# a read-only source can't be used directly as cwd for the conf file mangosd
# expects to also be able to write to (e.g. realmlist changes).
mkdir -p /app/logs /out/etc
cp -f /app/etc/mangosd.conf /out/etc/mangosd.conf
cp -f /app/etc/realmd.conf  /out/etc/realmd.conf

cd /app/bin

# mangosd/realmd run an interactive console reader on stdin and treat EOF as
# an implicit "quit" (CliRunnable.cpp: feof(stdin) -> World::StopNow()) — the
# server otherwise fully starts (DB connected, world initialized, ports
# bound) and then shuts itself down cleanly seconds later. `docker run -i`
# doesn't reliably keep a real writer attached in detached mode, so redirect
# each child's stdin here instead, from a process substitution that never
# writes and never exits — this works regardless of Docker's own stdin
# plumbing, since it's entirely internal to the container's process tree.
./realmd < <(sleep infinity) &
realmd_pid=$!

# mangosd gets a real FIFO instead, so admin commands (account creation —
# see vanilla-wow.sh's 'create-account') can still reach its console from
# outside the container. Holding a read-write fd open on it (fd 9) keeps the
# FIFO from ever reporting EOF to a reader, same effect as the process
# substitution above, but it's also externally writable, e.g.
# `docker exec <container> sh -c 'echo "account create bob pass" > /app/mangosd.stdin'`.
mkfifo /app/mangosd.stdin
exec 9<>/app/mangosd.stdin
./mangosd < /app/mangosd.stdin &
mangosd_pid=$!

_shutdown() {
    local exit_code="${1:-0}"
    echo "Shutting down..."
    kill -TERM "$realmd_pid" "$mangosd_pid" 2>/dev/null || true
    wait "$realmd_pid" "$mangosd_pid" 2>/dev/null || true
    exit "$exit_code"
}
trap '_shutdown 0' TERM INT

# Exit as soon as either process dies — 'wait -n' returns that child's status.
wait -n "$realmd_pid" "$mangosd_pid"
status=$?
echo "A server process exited (status ${status}) — shutting down the other."
_shutdown "$status"
