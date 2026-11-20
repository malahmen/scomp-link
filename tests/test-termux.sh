#!/usr/bin/env bash
# Termux (Android): setup.sh, the package helpers and the launcher on a phone.
#
# Termux has no /etc/os-release, no root and no sudo; packages come from
# `pkg`, and its prefix is /data/data/com.termux/files/usr. Here that is
# pretended with PREFIX (what the detection reads besides TERMUX_VERSION), so
# this runs on any host; the real thing was checked in the termux/termux-docker
# image.
#
# What it protects:
#   - setup.sh knows Termux (it used to stop at "Cannot determine Linux
#     distribution") and does not install mise there;
#   - _pkg_manager picks pkg on Termux even though apt-get is there too, and
#     _ensure_pkg installs the Termux package name with pkg, without sudo;
#   - the launcher leaves out a script marked "# termux: <reason>", says how
#     many it left out, and shows them all with SCOMP_SHOW_ALL=1 - and changes
#     nothing off Termux.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
    echo "SKIP - bash 4+ not found (the launcher needs it)"; exit 77
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

TERMUX_PREFIX=/data/data/com.termux/files/usr
mkdir -p "$T/bin" "$T/home"
# pkg and apt-get stubs: record, succeed. Both exist on Termux.
printf '#!/usr/bin/env bash\nprintf "pkg %%s\\n" "$*" >> "%s/calls"\n' "$T" > "$T/bin/pkg"
printf '#!/usr/bin/env bash\nprintf "apt-get %%s\\n" "$*" >> "%s/calls"\n' "$T" > "$T/bin/apt-get"
printf '#!/usr/bin/env bash\nprintf "sudo %%s\\n" "$*" >> "%s/calls"\n' "$T" > "$T/bin/sudo"
chmod +x "$T/bin/"*

# termux <cmd>...: run with Termux's PREFIX, without TERMUX_VERSION (as in
# termux-docker), the stubs first on PATH.
termux() { env -u TERMUX_VERSION PREFIX="$TERMUX_PREFIX" HOME="$T/home" PATH="$T/bin:$PATH" "$@"; }
offhost() { env -u TERMUX_VERSION -u PREFIX HOME="$T/home" PATH="$T/bin:$PATH" "$@"; }

echo "# setup.sh"
# Its functions, without the run at the bottom (that starts at `detect_os`).
sed '/^detect_os$/,$d' "$REPO/setup.sh" > "$T/setup-fns.sh"
termux bash -c 'source "$1"; detect_os; echo "$OS $PKG_MANAGER"' _ "$T/setup-fns.sh" > "$T/out" 2>&1
check "Termux is detected by its prefix, without TERMUX_VERSION" grep -qx 'termux pkg' "$T/out"
env PREFIX=/usr TERMUX_VERSION=0.118.1 HOME="$T/home" bash -c 'source "$1"; detect_os; echo "$OS $PKG_MANAGER"' _ "$T/setup-fns.sh" > "$T/out" 2>&1
check "  or by TERMUX_VERSION, which the app sets" grep -qx 'termux pkg' "$T/out"
: > "$T/calls"
termux bash -c 'source "$1"; detect_os; ensure_mise; ensure_mise_activation; echo done' _ "$T/setup-fns.sh" > "$T/out" 2>&1
check "mise is skipped on Termux" has "mise is not needed" "$T/out"
check "  nothing is installed for it" test ! -s "$T/calls"
check "  and no shell rc file is touched" test -z "$(ls -A "$T/home")"

echo "# deps.sh"
# deps <function> <args>: deps.sh's function, with ui.sh's messages stubbed.
# A script, not a shell function, so that env (in termux/offhost) can run it.
cat > "$T/deps" <<EOF
#!/usr/bin/env bash
info() { echo "INFO \$*"; }; warn() { echo "WARN \$*"; }; error_exit() { echo "ERROR \$*"; exit 1; }
source "$REPO/scripts/_common/deps.sh"
"\$@"
EOF
termux bash "$T/deps" _pkg_manager > "$T/out" 2>&1
check "pkg is the package manager on Termux, though apt-get is there" grep -qx pkg "$T/out"
offhost bash "$T/deps" _pkg_manager > "$T/out" 2>&1
check "  off Termux, the same stubs give apt-get (or the host's own)" grep -qvx pkg "$T/out"
: > "$T/calls"
termux bash "$T/deps" _ensure_pkg scomp-no-such-bin dnf-name apt-name termux-name > "$T/out" 2>&1
check "_ensure_pkg installs the Termux name with pkg" grep -qx 'pkg install -y termux-name' "$T/calls"
check "  without sudo" lacks "sudo" "$T/calls"
: > "$T/calls"
termux bash "$T/deps" _ensure_pkg scomp-no-such-bin dnf-name apt-name > "$T/out" 2>&1
check "  and the apt name when no Termux name is given" grep -qx 'pkg install -y apt-name' "$T/calls"
: > "$T/calls"
termux bash "$T/deps" _ensure_pkgs "dnf-a dnf-b" "apt-a apt-b" > "$T/out" 2>&1
check "_ensure_pkgs installs the apt names with pkg" grep -qx 'pkg install -y apt-a apt-b' "$T/calls"

echo "# the launcher"
mkdir -p "$T/repo/scripts/fine" "$T/repo/scripts/needs-docker" "$T/repo/scripts/_common"
cp "$REPO/init.sh" "$T/repo/"
printf '#!/usr/bin/env bash\n# description: works anywhere\n' > "$T/repo/scripts/fine/fine.sh"
printf '#!/usr/bin/env bash\n# description: runs containers\n# termux: needs Docker\n' > "$T/repo/scripts/needs-docker/needs-docker.sh"
ln -s "$TEST_DIR/stubs/gum" "$T/bin/gum"
# Esc at the picker: the launcher says Bye. The stub shows what was offered.
launch() { : > "$T/state"; : > "$T/answers"; GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" "$@" bash "$T/repo/init.sh" > "$T/out" 2>&1; }
launch termux
check "on Termux, a script that works there is offered" has "<option> fine/fine.sh" "$T/out"
check "  one marked '# termux:' is not" lacks "needs-docker/needs-docker.sh" "$T/out"
check "  and the launcher says how many it left out" has "Termux: 1 scripts hidden" "$T/out"
launch termux env SCOMP_SHOW_ALL=1
check "SCOMP_SHOW_ALL=1 offers it on Termux" has "<option> needs-docker/needs-docker.sh" "$T/out"
check "  and hides nothing" lacks "scripts hidden" "$T/out"
launch offhost
check "off Termux, every script is offered" has "<option> needs-docker/needs-docker.sh" "$T/out"
check "  with no Termux note" lacks "Termux:" "$T/out"

echo "# every '# termux:' script says why"
while IFS= read -r f; do
    r="$(sed -n 's/^#[[:space:]]*termux:[[:space:]]*//p' "$f" | head -n1)"
    check "$(basename "$f"): '${r}'" test -n "$r"
done < <(grep -rlE '^#[[:space:]]*termux:' "$REPO/scripts" --include='*.sh' | sort)

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
