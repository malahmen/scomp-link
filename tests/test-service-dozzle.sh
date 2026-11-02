#!/usr/bin/env bash
# dozzle.sh's authentication and port-forward (Kamino 235), driven through the
# gum stub against the recording docker/kubectl stubs (tests/lib/
# service-stubs.sh). Nothing real is reached.
#
# What it protects:
#   - Dozzle before 11 takes the password to hash only as --password, on
#     docker's command line: authentication with such a version is refused
#     before a username or password is asked, and nothing is installed. It
#     used to be the fallback, with a warning;
#   - Dozzle 11 and later get it on stdin, and a `generate` that fails is
#     reported, nothing is installed and no --password retry follows;
#   - a port-forward that fails to start says so and returns to the menu:
#     it was error_exit, which ended the whole TUI.
set -uo pipefail

# shellcheck source=lib/service-stubs.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/service-stubs.sh"

# The GitHub release list select_version reads: two stable tags.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
[[ "$*" == *api.github.com* ]] && printf '  "tag_name": "v11.0.2",\n  "tag_name": "v10.4.1",\n  "tag_name": "v8.14.1",\n'
exit 0
EOF
# docker: `generate` prints a users.yml and keeps its stdin, or fails when
# the test leaves $STUB_STATE/generate-fail.
mv "$T/bin/docker" "$T/bin/docker.stub"
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run && " $* " == *" generate "* ]]; then
    printf 'docker %s\n' "$*" >> "$STUB_LOG"
    [[ -t 0 ]] || cat > "$STUB_STATE/generate-stdin"
    [[ -e "$STUB_STATE/generate-fail" ]] && { echo "Unable to find image" >&2; exit 125; }
    printf 'users:\n    admin:\n        password: $2a$11$stubhash\n'
    exit 0
fi
exec "$(dirname "$0")/docker.stub" "$@"
EOF
chmod +x "$T/bin/curl" "$T/bin/docker"
PW="s3cret pass"
generated() { grep -q ' generate ' "$STUB_LOG"; }
installed() { grep -qE '^docker-compose .* up' "$STUB_LOG"; }

for v in v8.14.1 v10.4.1; do
    echo "dozzle docker: authentication with Dozzle ${v#v} is refused"
    svc_reset; rm -rf "$HOME/.config/dozzle"
    svc_cmd dozzle install "$v" yes admin "$PW" "" "" "$T/dz"
    check "install returns (exit 0)" rc_is 0
    check "it says why, and what to pick" bash -c 'grep -q "only on its command line (--password)" "$1" && grep -q "needs Dozzle 11 or later" "$1"' _ "$T/out"
    check "no username or password is asked" bash -c '! grep -q "header: Username:" "$1" && ! grep -q "<input> admin" "$1"' _ "$T/out"
    check "nothing is generated or installed" bash -c "! grep -qE ' generate |^docker-compose ' '$STUB_LOG'"
    check "the password is on no argv" lacks "$PW" "$STUB_LOG"
    check "no config is saved" test ! -e "$HOME/.config/dozzle/dozzle.conf"
done

echo "dozzle docker: Dozzle 8 without authentication still installs"
svc_reset; rm -rf "$HOME/.config/dozzle"
svc_cmd dozzle install v8.14.1 no "$T/dz"
check "install finishes (exit 0)" rc_is 0
check "it is installed" installed

echo "dozzle docker: Dozzle 11 hashes the password from stdin"
svc_reset; rm -rf "$HOME/.config/dozzle" "$T/dz"
svc_cmd dozzle install v11.0.2 yes admin "$PW" "" "" "$T/dz"
check "install finishes (exit 0)" rc_is 0
check "generate reads the password on stdin" bash -c '[[ "$(cat "$1")" == "$2" ]]' _ "$STUB_STATE/generate-stdin" "$PW"
check "the password is on no argv" lacks "$PW" "$STUB_LOG"
check "it is installed" installed

echo "dozzle docker: generate fails - reported, no --password retry, nothing installed"
svc_reset; rm -rf "$HOME/.config/dozzle" "$T/dz"; touch "$STUB_STATE/generate-fail"
svc_cmd dozzle install v11.0.2 yes admin "$PW" "" "" "$T/dz"
check "install returns (exit 0)" rc_is 0
check "generate ran once, without --password" bash -c "[[ \$(grep -c ' generate ' '$STUB_LOG') == 1 ]] && ! grep -q -- '--password' '$STUB_LOG'"
check "it says so" has "generate' failed" "$T/out"
check "nothing is installed" bash -c "! grep -q '^docker-compose ' '$STUB_LOG'"
check "the password is on no argv" lacks "$PW" "$STUB_LOG"

echo "dozzle k8s: a port-forward that does not start returns to the menu"
# kubectl's port-forward (the stub) exits at once: nothing listens.
svc_reset; rm -rf "$HOME/.config/dozzle"; mkdir -p "$HOME/.config/dozzle"
printf '%s\n' TARGET_TYPE=kind TARGET_CONTEXT=lab DOZZLE_VERSION=v11.0.2 STORAGE_MODE=hostpath > "$HOME/.config/dozzle/dozzle.conf"
echo lab > "$STUB_STATE/kind-clusters"
svc_run dozzle port-forward "" yes quit
check "the script finishes (exit 0), at the menu's quit" bash -c 'rc_is() { [[ "$(cat "$1")" == 0 ]]; }; rc_is "$1" && grep -q "Bye." "$2"' _ "$T/rc" "$T/out"
check "it says the port-forward failed" has "Port-forward failed to start" "$T/out"
check "and the menu asked to go back" has "Back to main menu?" "$T/out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
