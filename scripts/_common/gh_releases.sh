#!/usr/bin/env bash
# GitHub release helpers.  Sourced by app scripts — do NOT run directly.
# select_version() sets SELECTED_VERSION in the caller's scope.

select_version() {
    local api_url="$1"
    local label="$2"

    info "Fetching available ${label} versions from GitHub..."

    local versions
    if ! versions=$(gum spin --spinner dot --title "Fetching release list..." -- \
        bash -c "curl -fsSL '${api_url}?per_page=30' 2>/dev/null \
            | grep '\"tag_name\"' \
            | sed 's/.*\"tag_name\": *\"\(.*\)\".*/\1/' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+\$'"); then
        gum log --level warn "Failed to fetch version list. Falling back to latest stable."
        SELECTED_VERSION="latest"
        return
    fi

    if [[ -z "$versions" ]]; then
        gum log --level error "No stable releases found. Check your internet connection."
        exit 1
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
