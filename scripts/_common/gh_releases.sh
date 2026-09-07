#!/usr/bin/env bash
# GitHub release helpers.  Sourced by app scripts — do NOT run directly.
# select_version() sets SELECTED_VERSION in the caller's scope.

select_version() {
    local api_url="$1"
    local label="$2"

    info "Fetching available ${label} versions from GitHub..."

    # Fetch first (curl -f fails on HTTP errors), THEN filter — so a genuine fetch
    # failure and "fetched fine, but no stable tags" are distinguished. Doing both
    # in one piped `bash -c` made the pipeline's exit status the final grep's, so a
    # repo with only pre-releases looked like a network failure.
    local raw
    if ! raw=$(gum spin --spinner dot --title "Fetching release list..." -- \
        curl -fsSL "${api_url}?per_page=30" 2>/dev/null); then
        gum log --level warn "Failed to fetch version list. Falling back to latest stable."
        SELECTED_VERSION="latest"
        return
    fi

    local versions
    versions=$(printf '%s' "$raw" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"\(.*\)".*/\1/' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)

    if [[ -z "$versions" ]]; then
        gum log --level warn "No stable (vX.Y.Z) ${label} releases found — falling back to latest."
        SELECTED_VERSION="latest"
        return
    fi

    SELECTED_VERSION=$(echo "$versions" | gum choose \
        --header "Select ${label} version (stable releases only):" \
        --height 10) || true

    if [[ -z "$SELECTED_VERSION" ]]; then
        gum log --level warn "No version selected. Aborting."
        exit 0
    fi

    info "Selected version: ${SELECTED_VERSION}"
}
