#!/usr/bin/env bash
# Folders a script creates, and may therefore delete.  Sourced by app scripts —
# do NOT run directly.
#
# An uninstall used to `rm -rf` whatever data path the user had typed at
# install - a `projects` folder was deleted that way (Kamino 176). Now a
# script deletes a folder only if it created it: owned_dir_create writes a
# marker into each folder it makes, and owned_dir_remove deletes only a folder
# carrying that marker. A folder that already existed is used, never deleted.
# `/`, $HOME and any folder that contains $HOME are refused outright.

OWNED_MARKER=".scomp-link-owned"

# owned_dir_abs <path> - the absolute, ~-expanded spelling of <path> (no
# symlink resolution needed: the checks below compare canonical forms).
owned_dir_abs() {
    local p="${1/#\~/$HOME}"
    [[ "$p" == /* ]] || p="${PWD}/${p}"
    # collapse trailing slashes (but keep "/")
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    printf '%s' "$p"
}

# _owned_dir_canon <path> - the physical path of an existing directory.
_owned_dir_canon() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# owned_dir_forbidden <path> - true for /, $HOME, or a folder that contains
# $HOME (/home, /Users). Compared physically when the folder exists.
owned_dir_forbidden() {
    local p home
    p="$(owned_dir_abs "$1")"
    [[ -d "$p" ]] && p="$(_owned_dir_canon "$p")"
    home="$(_owned_dir_canon "$HOME")"; home="${home:-$HOME}"
    [[ "$p" == "/" || "$p" == "$home" || "$home" == "$p"/* ]]
}

# owned_dir_create <path> <owner> - mkdir -p <path>; when it did not exist,
# marks it as created by <owner>. Prints nothing; returns 1 for a forbidden path.
owned_dir_create() {
    local p owner="$2"
    p="$(owned_dir_abs "$1")"
    owned_dir_forbidden "$p" && return 1
    if [[ ! -e "$p" ]]; then
        mkdir -p -- "$p" || return 1
        printf 'Created by %s; removed with it on uninstall/purge.\n' "$owner" > "${p}/${OWNED_MARKER}"
    else
        mkdir -p -- "$p" || return 1
    fi
}

# owned_dir_owned <path> - true when the folder carries the marker.
owned_dir_owned() { [[ -f "$(owned_dir_abs "$1")/${OWNED_MARKER}" ]]; }

# owned_dir_plan <path> - what owned_dir_remove would do, one word:
#   absent   nothing there
#   refuse   /, $HOME or a folder that contains it
#   delete   created by the script (marker present): removed with its contents
#   keep     not created by the script: left alone
owned_dir_plan() {
    local p
    p="$(owned_dir_abs "$1")"
    if [[ ! -e "$p" ]]; then echo absent
    elif owned_dir_forbidden "$p"; then echo refuse
    elif [[ -d "$p" ]] && owned_dir_owned "$p"; then echo delete
    else echo keep
    fi
}

# owned_dir_remove <path> - deletes <path> only when its plan is "delete".
# Returns 0 when there was nothing to do or the folder is gone, 1 when the
# delete failed (files owned by a container's user, say).
owned_dir_remove() {
    local p
    p="$(owned_dir_abs "$1")"
    [[ "$(owned_dir_plan "$p")" == delete ]] || return 0
    rm -rf -- "$p" 2>/dev/null
    [[ ! -e "$p" ]]
}
