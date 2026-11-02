#!/usr/bin/env bash
# Saved settings as KEY=VALUE lines, read without `source`.  Sourced by app
# scripts — do NOT run directly.
#
# Kamino 196: dozzle, lgtm, bazzite-utils and lmstudio wrote KEY="${value}"
# with the value pasted in raw and then `source`d the file, so a value holding
# a quote, a $(...) or a backtick - a typed path, an image tag or namespace
# read back from a cluster - ran as code the next time the script started.
# Now values are written with printf %q and read back by a parser that runs
# nothing and sets only the keys the caller names.
#
# Files written by the old code (KEY="value", nothing escaped inside) still
# read back the same.

# _conf_decode <raw> - the value of one line's right-hand side, printed.
# Accepts what conf_write writes (printf %q: backslash escapes, '' for empty)
# and the old KEY="value" form. Returns 1 for anything else ($'...' control
# characters, unbalanced quotes), which the caller skips.
_conf_decode() {
    local v="$1" out="" c
    if [[ "$v" == \"*\" && ${#v} -ge 2 ]]; then          # old form: "value", taken as is
        printf '%s' "${v:1:${#v}-2}"; return 0
    fi
    if [[ "$v" == \'*\' && ${#v} -ge 2 ]]; then          # '' or 'value' (no quote inside)
        v="${v:1:${#v}-2}"
        [[ "$v" == *\'* ]] && return 1
        printf '%s' "$v"; return 0
    fi
    if [[ "$v" == \$\'* ]]; then
        # $'...' is what %q writes for control or (in some locales) non-ASCII
        # characters. Only a single ANSI-C literal with no unescaped quote
        # inside is accepted, and $'...' expands nothing, so this eval cannot
        # run code; anything else is refused.
        local re="^\\$'([^'\\\\]|\\\\.)*'\$"
        [[ "$v" =~ $re ]] || return 1
        eval "out=$v"
        printf '%s' "$out"; return 0
    fi
    while [[ -n "$v" ]]; do
        c="${v:0:1}"
        if [[ "$c" == \\ ]]; then
            [[ ${#v} -ge 2 ]] || return 1
            out+="${v:1:1}"; v="${v:2}"
        else
            # An unescaped quote, $ or backtick is not something %q writes.
            [[ "$c" == [\"\'\`\$] ]] && return 1
            out+="$c"; v="${v:1}"
        fi
    done
    printf '%s' "$out"
}

# conf_get <file> <KEY> - prints the KEY's value (empty if unset or unreadable).
conf_get() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 0
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1)" || true
    [[ -n "$line" ]] || return 0
    _conf_decode "${line#*=}" || true
}

# conf_load <file> <KEY>... - sets each named KEY that the file holds; other
# lines are ignored. A value it cannot read is skipped with a warning (the
# caller's default stays).
conf_load() {
    local file="$1" line key raw val; shift
    [[ -f "$file" ]] || return 0
    local -A want=()
    for key in "$@"; do want[$key]=1; done
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}" raw="${BASH_REMATCH[2]}"
        [[ -n "${want[$key]:-}" ]] || continue
        if val="$(_conf_decode "$raw")"; then
            printf -v "$key" '%s' "$val"
        else
            warn "Ignoring ${key} in ${file}: not a value this script wrote (edit or delete that line)."
        fi
    done < "$file"
}

# conf_write <file> <KEY>... - writes the named variables, one KEY=%q line each.
conf_write() {
    local file="$1" key; shift
    {
        for key in "$@"; do printf '%s=%q\n' "$key" "${!key:-}"; done
    } > "$file"
}

# conf_set <file> <KEY> <value> - sets one KEY in place, keeping the other lines.
conf_set() {
    local file="$1" key="$2" val="$3" tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    { grep -vE "^${key}=" "$file" 2>/dev/null || true; printf '%s=%q\n' "$key" "$val"; } > "$tmp"
    mv -f "$tmp" "$file"
}
