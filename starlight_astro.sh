#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# starlight.sh
# Interactive TUI for creating and managing Astro Starlight documentation projects.
# Called by common.sh — expects gum to already be available.
# Dependencies: gum (managed by common.sh), npm, vim
# Optional: tree (site structure view)
# -----------------------------------------------------------------------------

set -uo pipefail

# -----------------------------------------------------------------------------
# Bash version guard — requires bash 4+ (associative arrays, nameref, etc.)
# macOS ships bash 3.2; install via brew and ensure it's first on PATH.
# -----------------------------------------------------------------------------
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "[error] bash 4 or higher is required (you have bash ${BASH_VERSION})."
    echo "  On macOS: brew install bash"
    echo "  Then ensure /opt/homebrew/bin or /usr/local/bin is before /usr/bin in PATH."
    exit 1
fi

# -----------------------------------------------------------------------------
# Constants & colours
# -----------------------------------------------------------------------------

CYAN=212
RED=196
GREEN=82
YELLOW=220

# Script-level globals
ORIGIN_DIR="$(pwd)"        # Directory the script was launched from
PROJECT_DIR=""             # Currently active project directory
HAS_TREE=0

# Globals set during create flow
PROJECT_NAME=""
PROJECT_SLUG=""
SITE_DESCRIPTION=""
SIDEBAR_ENTRIES=()
EXTERNAL_LINKS=()
ENABLE_MERMAID=false

# Globals used by management
DOCS_DIR="src/content/docs"
CONFIG_FILE="astro.config.mjs"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

header() {
    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border rounded \
        --align center --width 60 --padding "1 4" --margin "1 0" \
        "$1"
}

info()       { gum log --level info "$1"; }
success()    { gum style --foreground "$GREEN" "[ok] $1"; }
warn()       { gum style --foreground "$YELLOW" "[warn] $1"; }
error_exit() { gum style --foreground "$RED" "[error] $1"; exit 1; }

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_'
}

# Returns to ORIGIN_DIR — called before any operation that needs to rescan
return_to_origin() {
    cd "$ORIGIN_DIR" || error_exit "Cannot return to origin directory: ${ORIGIN_DIR}"
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------

preflight_checks() {
    if ! command -v gum &>/dev/null; then
        echo "[error] gum is not installed. Please run setup.sh first."
        exit 1
    fi

    if ! command -v npm &>/dev/null; then
        error_exit "npm is not installed. Please run setup.sh to install Node.js/npm, then re-run."
    fi

    local node_major
    node_major=$(node -e "process.stdout.write(String(process.versions.node.split('.')[0]))")
    if [[ "$node_major" -lt 18 ]] || [[ "$node_major" -eq 19 ]] || [[ "$node_major" -eq 21 ]]; then
        error_exit "Node.js v${node_major} is not supported by Astro. Supported: v18.20.8+, v20.3.0+, v22+. Please update via setup.sh."
    fi

    if ! command -v vim &>/dev/null; then
        error_exit "vim is not installed. Please run setup.sh first."
    fi

    if command -v tree &>/dev/null; then
        HAS_TREE=1
    fi
}

# -----------------------------------------------------------------------------
# Project discovery
# -----------------------------------------------------------------------------

scan_projects() {
    # Returns newline-separated list of dirs containing astro.config.mjs,
    # relative to ORIGIN_DIR, depth 3. Empty if none found.
    find "$ORIGIN_DIR" -maxdepth 3 -name "astro.config.mjs" 2>/dev/null \
        | sed "s|/astro.config.mjs||" \
        | sed "s|^${ORIGIN_DIR}/||" \
        | sed "s|^${ORIGIN_DIR}$|.|" \
        | sort
}

# =============================================================================
# CREATE FLOW
# =============================================================================

create_collect_project_info() {
    header "New Project — Setup"

    PROJECT_NAME=$(gum input --width 60 \
        --placeholder "Project name (e.g. my-docs)" \
        --char-limit 64) || true
    [[ -z "$PROJECT_NAME" ]] && { warn "Cancelled."; return 1; }

    PROJECT_SLUG=$(slugify "$PROJECT_NAME")
    [[ -z "$PROJECT_SLUG" ]] && { warn "Project name produced an empty slug."; return 1; }

    if [[ -d "${ORIGIN_DIR}/${PROJECT_SLUG}" ]]; then
        warn "Directory '${PROJECT_SLUG}' already exists."
        if ! gum confirm "Continue anyway? (existing files may conflict)"; then
            warn "Cancelled."
            return 1
        fi
    fi

    SITE_DESCRIPTION=$(gum input --width 60 \
        --placeholder "Site description (e.g. Documentation for ${PROJECT_NAME})" \
        --char-limit 160) || true
    [[ -z "$SITE_DESCRIPTION" ]] && SITE_DESCRIPTION="Documentation for ${PROJECT_NAME}"

    if gum confirm "Enable Mermaid diagram support?"; then
        ENABLE_MERMAID=true
        info "Mermaid support enabled — diagrams will render in the browser and in PDF exports."
    else
        ENABLE_MERMAID=false
    fi

    success "Project: ${PROJECT_NAME} → ./${PROJECT_SLUG}"
}

create_scaffold() {
    header "Scaffolding Starlight"

    info "Running: npm create astro@latest -- --template starlight --yes"

    gum spin --spinner dot --title "Creating Starlight project in ./${PROJECT_SLUG} ..." -- \
        npm create astro@latest "$PROJECT_SLUG" -- --template starlight --yes --no-install

    [[ ! -d "${ORIGIN_DIR}/${PROJECT_SLUG}" ]] && { warn "Scaffolding failed — directory not created."; return 1; }
    success "Scaffolded at ./${PROJECT_SLUG}"

    cd "${ORIGIN_DIR}/${PROJECT_SLUG}"

    gum spin --spinner dot --title "Installing dependencies ..." -- \
        npm install

    success "Dependencies installed."

    # ── converter/ folder ────────────────────────────────────────────────────
    header "Setting Up Converter"

    mkdir -p converter

    # Copy convert.sh from alongside starlight_astro.sh
    local converter_script="${SCRIPT_DIR}/converter/convert.sh"
    if [[ -f "$converter_script" ]]; then
        cp "$converter_script" converter/convert.sh
        chmod +x converter/convert.sh
        success "convert.sh copied to converter/"
    else
        warn "converter/convert.sh not found at ${converter_script} — skipping."
        warn "Copy it manually before running mise tasks."
    fi

    # Copy .fcc/ assets if they exist next to starlight_astro.sh
    local fcc_source="${SCRIPT_DIR}/.fcc"
    if [[ -d "$fcc_source" ]]; then
        cp -r "$fcc_source" converter/.fcc
        success ".fcc/ assets copied to converter/.fcc/"
    else
        warn ".fcc/ not found at ${fcc_source}."
        warn "converter/.fcc/pdf/ will be created on first conversion run,"
        warn "but p10k.theme, widen-tables.lua, and render-mermaid.lua will be missing."
        warn "PDF conversion will fail until those files are placed in converter/.fcc/pdf/."
        mkdir -p converter/.fcc/pdf
        mkdir -p converter/.fcc/title-pages
    fi

    success "converter/ ready."

    # ── mise.toml ────────────────────────────────────────────────────────────
    local mermaid_tool=""
    if [[ "$ENABLE_MERMAID" == "true" ]]; then
        mermaid_tool=$'\n'"\"npm:@mermaid-js/mermaid-cli\" = \"11.12.0\""
    fi

    cat > mise.toml << MISEEOF
[tools]${mermaid_tool}

[tasks.dev]
description = "Start Starlight dev server"
run = "npm run dev"

[tasks.build]
description = "Build the Starlight site"
run = "npm run build"

[tasks.preview]
description = "Preview the production build"
run = "npm run preview"

[tasks.convert]
description = "Convert docs interactively (full options: format, engine, font, title page)"
run = "bash converter/convert.sh full"

[tasks."convert:pdf"]
description = "Convert a document to PDF, file picker only, xelatex, helvetica, title page"
run = "bash converter/convert.sh pdf"
MISEEOF

    mise trust mise.toml

    gum spin --spinner dot --title "Installing mise tools (this may take a moment)..." -- \
        mise install

    success "mise.toml created, trusted, and tools installed."
}

create_cleanup_defaults() {
    header "Cleaning Up Template Defaults"

    local docs_dir="src/content/docs"

    for default_dir in guides reference; do
        if [[ -d "${docs_dir}/${default_dir}" ]]; then
            rm -rf "${docs_dir:?}/${default_dir}"
            success "Removed default '${default_dir}/' folder"
        fi
    done

    cat > "${docs_dir}/index.mdx" <<HOMEEOF
---
title: ${PROJECT_NAME}
description: ${SITE_DESCRIPTION}
#template: splash
hero:
  title: ${PROJECT_NAME}
  tagline: ${SITE_DESCRIPTION}
  actions:
    - text: Get Started
      link: /
      icon: right-arrow
---

Welcome to the **${PROJECT_NAME}** documentation.
HOMEEOF

    success "Homepage reset to clean slate."
    info "Note: astro.config.mjs will be fully replaced in the next step."
}

create_collect_sections() {
    header "Documentation Sections"
    info "Define the top-level sections (folders) for your docs."
    info "Each becomes a directory under src/content/docs/ and a sidebar group."
    info "Press ESC or leave blank when done."

    SIDEBAR_ENTRIES=()

    while true; do
        echo ""
        local section_folder
        section_folder=$(gum input --width 60 \
            --placeholder "e.g. guides  (leave blank to finish)" \
            --char-limit 64) || true
        [[ -z "$section_folder" ]] && break

        section_folder=$(slugify "$section_folder")
        [[ -z "$section_folder" ]] && { warn "Invalid folder name, skipping."; continue; }

        local section_label
        section_label=$(gum input --width 60 \
            --placeholder "e.g. Guides" \
            --char-limit 64) || true
        [[ -z "$section_label" ]] && section_label="$section_folder"

        local section_mode
        section_mode=$(gum choose \
            --header "Sidebar mode for '${section_label}':" \
            "autogenerate" \
            "strict (manual items)") || true
        [[ -z "$section_mode" ]] && { warn "No mode selected, skipping section."; continue; }

        mkdir -p "src/content/docs/${section_folder}"

        cat > "src/content/docs/${section_folder}/index.md" <<MDEOF
---
title: ${section_label}
description: ${section_label} section of ${PROJECT_NAME}.
---

Welcome to the **${section_label}** section.
MDEOF

        if [[ "$section_mode" == "autogenerate" ]]; then
            SIDEBAR_ENTRIES+=("{ label: '${section_label}', autogenerate: { directory: '${section_folder}' } }")
            success "Section '${section_folder}' → autogenerate"
        else
            info "Add slugs for '${section_label}' (e.g. ${section_folder}/getting-started). Blank to finish."
            local strict_items=()
            while true; do
                local item_slug
                item_slug=$(gum input --width 60 \
                    --placeholder "${section_folder}/page-slug  (blank to finish)" \
                    --char-limit 128) || true
                [[ -z "$item_slug" ]] && break
                strict_items+=("'${item_slug}'")
            done

            if [[ ${#strict_items[@]} -eq 0 ]]; then
                warn "No items specified, falling back to autogenerate for '${section_label}'."
                SIDEBAR_ENTRIES+=("{ label: '${section_label}', autogenerate: { directory: '${section_folder}' } }")
            else
                local items_js
                items_js=$(IFS=", "; echo "${strict_items[*]}")
                SIDEBAR_ENTRIES+=("{ label: '${section_label}', items: [ ${items_js} ] }")
            fi
            success "Section '${section_folder}' → strict (${#strict_items[@]} items)"
        fi
    done

    [[ ${#SIDEBAR_ENTRIES[@]} -eq 0 ]] && warn "No sections defined — sidebar will use Starlight's default filesystem autogeneration."
}

create_collect_external_links() {
    header "External Links"
    info "Add links to external resources (GitHub, docs, wikis, etc.)."
    info "Leave URL blank when done."

    EXTERNAL_LINKS=()

    while true; do
        echo ""
        local ext_url
        ext_url=$(gum input --width 60 \
            --placeholder "https://github.com/org/repo  (blank to finish)" \
            --char-limit 256) || true
        [[ -z "$ext_url" ]] && break

        local ext_label
        ext_label=$(gum input --width 60 \
            --placeholder "e.g. GitHub Repository" \
            --char-limit 64) || true
        [[ -z "$ext_label" ]] && ext_label="$ext_url"

        local ext_placement
        ext_placement=$(gum choose \
            --header "Where should '${ext_label}' appear?" \
            "top-level sidebar link" \
            "inside a sidebar group" \
            "homepage only (no sidebar)") || true
        [[ -z "$ext_placement" ]] && { warn "No placement selected, skipping link."; continue; }

        if [[ "$ext_placement" == "inside a sidebar group" ]]; then
            local ext_group
            ext_group=$(gum input --width 60 \
                --placeholder "e.g. Resources" \
                --char-limit 64) || true
            [[ -z "$ext_group" ]] && ext_group="Resources"
            EXTERNAL_LINKS+=("group|${ext_group}|${ext_label}|${ext_url}")
        elif [[ "$ext_placement" == "top-level sidebar link" ]]; then
            EXTERNAL_LINKS+=("top|${ext_label}|${ext_url}")
        else
            EXTERNAL_LINKS+=("home|${ext_label}|${ext_url}")
            info "→ '${ext_label}' noted as homepage-only. Add it to src/content/docs/index.mdx manually, or use the link cards component."
        fi

        success "Added: ${ext_label} → ${ext_url}"
    done
}

create_build_config() {
    header "Writing astro.config.mjs"

    local all_sidebar_entries=()

    [[ ${#SIDEBAR_ENTRIES[@]} -gt 0 ]] && all_sidebar_entries+=("${SIDEBAR_ENTRIES[@]}")

    # Merge "group" external links into named groups using parallel arrays
    local grp_names=()
    local grp_items=()

    for entry in "${EXTERNAL_LINKS[@]+"${EXTERNAL_LINKS[@]}"}"; do
        IFS='|' read -r type rest <<< "$entry"
        if [[ "$type" == "group" ]]; then
            IFS='|' read -r grp_name lbl url <<< "$rest"
            local new_item="{ label: '${lbl}', link: '${url}', attrs: { target: '_blank' } },"
            local found=0
            for (( gi=0; gi<${#grp_names[@]}; gi++ )); do
                if [[ "${grp_names[$gi]}" == "$grp_name" ]]; then
                    grp_items[$gi]="${grp_items[$gi]} ${new_item}"
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                grp_names+=("$grp_name")
                grp_items+=("$new_item")
            fi
        fi
    done

    for (( gi=0; gi<${#grp_names[@]}; gi++ )); do
        all_sidebar_entries+=("{ label: '${grp_names[$gi]}', items: [ ${grp_items[$gi]} ] }")
    done

    for entry in "${EXTERNAL_LINKS[@]+"${EXTERNAL_LINKS[@]}"}"; do
        IFS='|' read -r type rest <<< "$entry"
        if [[ "$type" == "top" ]]; then
            IFS='|' read -r lbl url <<< "$rest"
            all_sidebar_entries+=("{ label: '${lbl}', link: '${url}', attrs: { target: '_blank' } }")
        fi
    done

    local sidebar_block="[]"
    if [[ ${#all_sidebar_entries[@]} -gt 0 ]]; then
        sidebar_block="["$'\n'
        local count=${#all_sidebar_entries[@]}
        for (( i=0; i<count; i++ )); do
            if [[ $i -lt $(( count - 1 )) ]]; then
                sidebar_block+="        ${all_sidebar_entries[$i]},"$'\n'
            else
                sidebar_block+="        ${all_sidebar_entries[$i]}"$'\n'
            fi
        done
        sidebar_block+="      ]"
    fi

    local safe_name="${PROJECT_NAME//\'/\\\'}"
    local safe_desc="${SITE_DESCRIPTION//\'/\\\'}"

    # Build optional mermaid blocks
    local mermaid_import="" mermaid_remark="" mermaid_head="" mermaid_markdown=""

    if [[ "$ENABLE_MERMAID" == "true" ]]; then
        mermaid_remark='
// Remark plugin that converts ```mermaid code blocks to raw HTML before
// Expressive Code (Starlight'"'"'s syntax highlighter) can process them.
// This lets mermaid.js render the diagrams client-side.
function remarkMermaid() {
  return (tree) => {
    (function walk(node) {
      if (node.type === '"'"'code'"'"' && node.lang === '"'"'mermaid'"'"') {
        const escaped = node.value
          .replace(/&/g, '"'"'&amp;'"'"')
          .replace(/</g, '"'"'&lt;'"'"')
          .replace(/>/g, '"'"'&gt;'"'"');
        node.type = '"'"'html'"'"';
        node.value = `<pre class="mermaid">${escaped}</pre>`;
        delete node.lang;
        delete node.meta;
        return;
      }
      node.children?.forEach(walk);
    })(tree);
  };
}
'
        mermaid_head="      head: [
        {
          tag: 'script',
          attrs: { type: 'module' },
          content: \`
            import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
            mermaid.initialize({ startOnLoad: false });
            await mermaid.run({ querySelector: '.mermaid' });
          \`,
        },
      ],"
        mermaid_markdown="  markdown: {
    remarkPlugins: [remarkMermaid],
  },"
    fi

    cat > astro.config.mjs << CONFIGEOF
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
${mermaid_remark}
// https://astro.build/config
export default defineConfig({
  integrations: [
    starlight({
      title: '${safe_name}',
      description: '${safe_desc}',
      sidebar: ${sidebar_block},
${mermaid_head}
    }),
  ],
  ${mermaid_markdown}
});
CONFIGEOF

    success "astro.config.mjs written."
}

create_update_homepage() {
    local home_links=()
    for entry in "${EXTERNAL_LINKS[@]+"${EXTERNAL_LINKS[@]}"}"; do
        IFS='|' read -r type rest <<< "$entry"
        [[ "$type" == "home" ]] && home_links+=("$rest")
    done

    [[ ${#home_links[@]} -eq 0 ]] && return

    info "Appending homepage-only links to src/content/docs/index.mdx..."

    local index_file="src/content/docs/index.mdx"
    [[ ! -f "$index_file" ]] && index_file="src/content/docs/index.md"
    [[ ! -f "$index_file" ]] && { warn "Could not find index file — skipping homepage links."; return; }

    echo "" >> "$index_file"
    echo "## External Resources" >> "$index_file"
    echo "" >> "$index_file"
    for link_data in "${home_links[@]}"; do
        IFS='|' read -r lbl url <<< "$link_data"
        echo "- [${lbl}](${url})" >> "$index_file"
    done

    success "Homepage links appended to ${index_file}."
}

create_write_init_script() {
    header "Writing init.sh"

    cat > init.sh <<'INITEOF'
#!/usr/bin/env bash
# init.sh -- Start the Starlight development server
# Run this from the project root: bash init.sh

set -euo pipefail

if ! command -v npm &>/dev/null; then
  echo "[error] npm is not installed. Please install Node.js first."
  exit 1
fi

if [[ ! -f "package.json" ]]; then
  echo "[error] No package.json found. Are you in the project root?"
  exit 1
fi

if [[ ! -d "node_modules" ]]; then
  echo "-> node_modules not found, installing dependencies..."
  npm install
fi

echo "-> Starting Starlight development server..."
echo "   Open your browser at: http://localhost:4321"
echo "   Press Ctrl+C to stop."
echo ""
npm run dev
INITEOF

    chmod +x init.sh
    success "init.sh written to project root."
}

create_print_summary() {
    echo ""
    gum style \
        --foreground "$GREEN" --border-foreground "$GREEN" --border rounded \
        --align center --width 60 --padding "1 4" --margin "1 0" \
        "[ok] ${PROJECT_NAME} is ready!"

    echo ""
    gum style --bold "What was created:"
    echo "  ./${PROJECT_SLUG}/                   Project root"
    echo "  ./${PROJECT_SLUG}/astro.config.mjs   Configured with your sidebar"
    echo "  ./${PROJECT_SLUG}/init.sh             Run this to start the dev server"

    if [[ ${#SIDEBAR_ENTRIES[@]} -gt 0 ]]; then
        echo ""
        gum style --bold "Sections created:"
        for entry in "${SIDEBAR_ENTRIES[@]}"; do
            local lbl
            lbl=$(echo "$entry" | sed "s/.*label: '\\([^']*\\)'.*/\\1/")
            echo "  src/content/docs/$(echo "$lbl" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')/"
        done
    fi

    echo ""
    gum style --bold "To start the site:"
    gum style --foreground "$CYAN" "  cd ${PROJECT_SLUG} && bash init.sh"
    echo ""
    gum style --faint "Or: cd ${PROJECT_SLUG} && npm run dev"
    echo ""
}

# Orchestrates the full create flow.
# On success: prompts user to manage now or return to list.
# On cancellation at any step: returns to origin and back to main loop.
create_project_flow() {
    header "Create New Project"

    # Reset globals for this run
    PROJECT_NAME=""
    PROJECT_SLUG=""
    SITE_DESCRIPTION=""
    SIDEBAR_ENTRIES=()
    EXTERNAL_LINKS=()
    ENABLE_MERMAID=false

    return_to_origin

    create_collect_project_info  || return
    create_scaffold              || { return_to_origin; return; }
    create_cleanup_defaults
    create_collect_sections
    create_collect_external_links
    create_build_config
    create_update_homepage
    create_write_init_script
    create_print_summary

    # At this point cwd is inside the new project (set by create_scaffold)
    local created_dir
    created_dir="$(pwd)"

    local next
    next=$(gum choose \
        "Manage it now" \
        "Back to project list" \
        --header "Project '${PROJECT_NAME}' created. What next?") || true

    case "$next" in
        "Manage it now")
            PROJECT_DIR="$created_dir"
            manage_menu
            ;;
        "Back to project list"|"")
            return_to_origin
            ;;
    esac
}

# =============================================================================
# MANAGE — utilities
# =============================================================================

list_sections() {
    find "$DOCS_DIR" -mindepth 1 -maxdepth 1 -type d | sort | sed "s|${DOCS_DIR}/||"
}

list_files_in_section() {
    local section="$1"
    find "${DOCS_DIR}/${section}" -maxdepth 1 -type f \( -name "*.md" -o -name "*.mdx" \) \
        | sort | sed "s|${DOCS_DIR}/${section}/||"
}

read_site_title() {
    sed -n "s/.*title: '\\([^']*\\)'.*/\\1/p" "$CONFIG_FILE" | head -1
}

rename_section_in_config() {
    local old_folder="$1"
    local new_folder="$2"
    local new_label="$3"
    sed -i.bak \
        -e "s|directory: '${old_folder}'|directory: '${new_folder}'|g" \
        -e "s|'${old_folder}'|'${new_folder}'|g" \
        "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    sed -i.bak \
        -e "s|label: '${old_folder}'|label: '${new_label}'|g" \
        "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
}

remove_section_from_config() {
    local folder="$1"
    grep -n "directory: '${folder}'" "$CONFIG_FILE" | while IFS=: read -r linenum _; do
        sed -i.bak "${linenum}d" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    done
}

pick_section() {
    local prompt="${1:-Select section:}"
    local sections
    sections=$(list_sections)
    [[ -z "$sections" ]] && { warn "No sections found."; echo ""; return; }
    echo "$sections" | gum choose --header "$prompt" || true
}

pick_file() {
    local section="$1"
    local prompt="${2:-Select file:}"
    local files
    files=$(list_files_in_section "$section")
    [[ -z "$files" ]] && { warn "No files in '${section}'."; echo ""; return; }
    echo "$files" | gum choose --header "$prompt" || true
}

# =============================================================================
# MANAGE — section actions
# =============================================================================

add_section() {
    header "Add Section"

    local folder label mode
    folder=$(gum input --width 60 \
        --placeholder "Folder name (e.g. runbooks)" \
        --char-limit 64) || true
    [[ -z "$folder" ]] && { warn "Cancelled."; return; }

    folder=$(slugify "$folder")
    [[ -z "$folder" ]] && { warn "Invalid folder name."; return; }

    if [[ -d "${DOCS_DIR}/${folder}" ]]; then
        warn "Section '${folder}' already exists."
        return
    fi

    label=$(gum input --width 60 \
        --placeholder "Display label (e.g. Runbooks)" \
        --char-limit 64) || true
    [[ -z "$label" ]] && label="$folder"

    mode=$(gum choose \
        --header "Sidebar mode for '${label}':" \
        "autogenerate" \
        "strict (manual items)") || true
    [[ -z "$mode" ]] && { warn "Cancelled."; return; }

    mkdir -p "${DOCS_DIR}/${folder}"
    local site_title
    site_title=$(read_site_title)

    cat > "${DOCS_DIR}/${folder}/index.md" << MDEOF
---
title: ${label}
description: ${label} section of ${site_title}.
---

Welcome to the **${label}** section.
MDEOF

    local entry
    if [[ "$mode" == "autogenerate" ]]; then
        entry="        { label: '${label}', autogenerate: { directory: '${folder}' } },"
    else
        entry="        { label: '${label}', items: [] },"
        warn "Strict mode: edit astro.config.mjs to add items manually under '${label}'."
    fi

    sed -i.bak "/sidebar: \[/{
    n
    /\]/{
      i\\
${entry}
    }
  }" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"

    if ! grep -q "directory: '${folder}'\|label: '${label}'" "$CONFIG_FILE"; then
        warn "Could not auto-insert into sidebar. Add this line manually to the sidebar array in astro.config.mjs:"
        gum style --foreground "$CYAN" "  ${entry}"
    fi

    success "Section '${folder}' created."
}

rename_section() {
    header "Rename Section"

    local sections
    sections=$(list_sections)
    [[ -z "$sections" ]] && { warn "No sections found."; return; }

    local old_folder
    old_folder=$(echo "$sections" | gum choose --header "Select section to rename:") || true
    [[ -z "$old_folder" ]] && { warn "Cancelled."; return; }

    local new_label
    new_label=$(gum input --width 60 \
        --placeholder "New display label (e.g. Operations)" \
        --char-limit 64) || true
    [[ -z "$new_label" ]] && { warn "Cancelled."; return; }

    local new_folder
    new_folder=$(gum input --width 60 \
        --placeholder "New folder name (leave blank to keep '${old_folder}')" \
        --char-limit 64) || true

    if [[ -z "$new_folder" ]]; then
        new_folder="$old_folder"
    else
        new_folder=$(slugify "$new_folder")
        [[ -z "$new_folder" ]] && { warn "Invalid folder name, keeping original."; new_folder="$old_folder"; }
    fi

    if [[ "$new_folder" != "$old_folder" ]]; then
        if [[ -d "${DOCS_DIR}/${new_folder}" ]]; then
            warn "A section named '${new_folder}' already exists. Rename aborted."
            return
        fi
        mv "${DOCS_DIR}/${old_folder}" "${DOCS_DIR}/${new_folder}"
        success "Folder renamed: ${old_folder} → ${new_folder}"
    fi

    rename_section_in_config "$old_folder" "$new_folder" "$new_label"
    success "Config updated for '${new_label}'."
    warn "If you use strict mode items, check astro.config.mjs for any remaining references to '${old_folder}'."
}

remove_section() {
    header "Remove Section"

    local sections
    sections=$(list_sections)
    [[ -z "$sections" ]] && { warn "No sections found."; return; }

    local folder
    folder=$(echo "$sections" | gum choose --header "Select section to remove:") || true
    [[ -z "$folder" ]] && { warn "Cancelled."; return; }

    local file_count
    file_count=$(find "${DOCS_DIR}/${folder}" -type f | wc -l | tr -d ' ')

    warn "This will permanently delete '${folder}/' and all ${file_count} file(s) inside it."
    if ! gum confirm "Are you sure?"; then
        warn "Cancelled."
        return
    fi

    remove_section_from_config "$folder"
    rm -rf "${DOCS_DIR:?}/${folder}"

    success "Section '${folder}' removed."
    warn "Review astro.config.mjs to confirm the sidebar entry was fully removed."
}

reorder_sections() {
    header "Reorder Sections"

    local sections
    sections=$(list_sections)
    [[ -z "$sections" ]] && { warn "No sections found."; return; }

    warn "Current sidebar order in astro.config.mjs:"
    grep -n "autogenerate\|items:" "$CONFIG_FILE" | head -20

    echo ""
    info "Reordering requires editing astro.config.mjs directly."
    info "Opening in vim now..."
    sleep 1
    vim "$CONFIG_FILE"
    success "Done editing config."
}

# =============================================================================
# MANAGE — file actions
# =============================================================================

add_file() {
    header "Add File"

    local section
    section=$(pick_section "Add file to which section?")
    [[ -z "$section" ]] && { warn "Cancelled."; return; }

    local filename
    filename=$(gum input --width 60 \
        --placeholder "File name (e.g. getting-started  — no extension)" \
        --char-limit 64) || true
    [[ -z "$filename" ]] && { warn "Cancelled."; return; }

    filename=$(slugify "$filename")
    [[ -z "$filename" ]] && { warn "Invalid file name."; return; }

    local ext
    ext=$(gum choose --header "File format:" "md" "mdx") || true
    [[ -z "$ext" ]] && ext="md"

    local filepath="${DOCS_DIR}/${section}/${filename}.${ext}"

    if [[ -f "$filepath" ]]; then
        warn "File '${filepath}' already exists."
        if ! gum confirm "Open it in vim anyway?"; then return; fi
        vim "$filepath"
        return
    fi

    local title
    title=$(gum input --width 60 \
        --placeholder "Page title (e.g. Getting Started)" \
        --char-limit 128) || true
    [[ -z "$title" ]] && title="$filename"

    local description
    description=$(gum input --width 60 \
        --placeholder "Short description (optional)" \
        --char-limit 200) || true

    cat > "$filepath" << PAGEEOF
---
title: ${title}
description: ${description}
---

## ${title}

Write your content here.
PAGEEOF

    success "Created: ${filepath}"

    if gum confirm "Open in vim now?"; then
        vim "$filepath"
    fi
}

edit_file() {
    header "Edit File"

    local section
    section=$(pick_section "File is in which section?")
    [[ -z "$section" ]] && { warn "Cancelled."; return; }

    local file
    file=$(pick_file "$section" "Select file to edit:")
    [[ -z "$file" ]] && { warn "Cancelled."; return; }

    vim "${DOCS_DIR}/${section}/${file}"
    success "Saved: ${section}/${file}"
}

rename_file() {
    header "Rename File"

    local section
    section=$(pick_section "File is in which section?")
    [[ -z "$section" ]] && { warn "Cancelled."; return; }

    local file
    file=$(pick_file "$section" "Select file to rename:")
    [[ -z "$file" ]] && { warn "Cancelled."; return; }

    local ext="${file##*.}"
    local new_name
    new_name=$(gum input --width 60 \
        --placeholder "New file name (no extension)" \
        --char-limit 64) || true
    [[ -z "$new_name" ]] && { warn "Cancelled."; return; }

    new_name=$(slugify "$new_name")
    [[ -z "$new_name" ]] && { warn "Invalid file name."; return; }

    local old_path="${DOCS_DIR}/${section}/${file}"
    local new_path="${DOCS_DIR}/${section}/${new_name}.${ext}"

    if [[ -f "$new_path" ]]; then
        warn "A file named '${new_name}.${ext}' already exists in '${section}'."
        return
    fi

    mv "$old_path" "$new_path"
    success "Renamed: ${file} → ${new_name}.${ext}"
    warn "If this file is referenced in astro.config.mjs (strict mode), update it manually."
}

move_file() {
    header "Move File"

    local src_section
    src_section=$(pick_section "Move file from which section?")
    [[ -z "$src_section" ]] && { warn "Cancelled."; return; }

    local file
    file=$(pick_file "$src_section" "Select file to move:")
    [[ -z "$file" ]] && { warn "Cancelled."; return; }

    local sections
    sections=$(list_sections | grep -v "^${src_section}$")
    [[ -z "$sections" ]] && { warn "No other sections to move to."; return; }

    local dst_section
    dst_section=$(echo "$sections" | gum choose --header "Move to which section?") || true
    [[ -z "$dst_section" ]] && { warn "Cancelled."; return; }

    local src_path="${DOCS_DIR}/${src_section}/${file}"
    local dst_path="${DOCS_DIR}/${dst_section}/${file}"

    if [[ -f "$dst_path" ]]; then
        warn "A file named '${file}' already exists in '${dst_section}'."
        if ! gum confirm "Overwrite?"; then return; fi
    fi

    mv "$src_path" "$dst_path"
    success "Moved: ${src_section}/${file} → ${dst_section}/${file}"
    warn "If this file is referenced in astro.config.mjs (strict mode), update it manually."
}

delete_file() {
    header "Delete File"

    local section
    section=$(pick_section "File is in which section?")
    [[ -z "$section" ]] && { warn "Cancelled."; return; }

    local file
    file=$(pick_file "$section" "Select file to delete:")
    [[ -z "$file" ]] && { warn "Cancelled."; return; }

    warn "This will permanently delete: ${section}/${file}"
    if ! gum confirm "Are you sure?"; then
        warn "Cancelled."
        return
    fi

    rm "${DOCS_DIR}/${section}/${file}"
    success "Deleted: ${section}/${file}"
}

# =============================================================================
# MANAGE — site actions
# =============================================================================

edit_homepage() {
    header "Edit Homepage"

    local index_file="${DOCS_DIR}/index.mdx"
    [[ ! -f "$index_file" ]] && index_file="${DOCS_DIR}/index.md"

    if [[ ! -f "$index_file" ]]; then
        warn "No index.mdx or index.md found in ${DOCS_DIR}."
        if gum confirm "Create a new index.mdx?"; then
            local site_title
            site_title=$(read_site_title)
            cat > "${DOCS_DIR}/index.mdx" << HOMEEOF
---
title: ${site_title}
description: Welcome to ${site_title}.
template: splash
hero:
  title: ${site_title}
  tagline: Welcome to ${site_title}.
  actions:
    - text: Get Started
      link: /
      icon: right-arrow
---

Welcome to the **${site_title}** documentation.
HOMEEOF
            index_file="${DOCS_DIR}/index.mdx"
            success "Created ${index_file}"
        else
            return
        fi
    fi

    vim "$index_file"
    success "Saved: ${index_file}"
}

view_structure() {
    header "Site Structure"
    echo ""
    tree -a --dirsfirst -I "node_modules|.git|dist|.astro" .
    echo ""
    gum confirm "Press Enter to continue" --affirmative "OK" --negative "" || true
}

edit_config() {
    header "Edit astro.config.mjs"
    warn "Editing the config directly. Be careful with syntax."
    sleep 1
    vim "$CONFIG_FILE"
    success "Config saved."
}

# =============================================================================
# MANAGE MENU
# =============================================================================

manage_menu() {
    # Ensure we're in the project directory
    cd "$PROJECT_DIR" || error_exit "Cannot enter project directory: ${PROJECT_DIR}"

    while true; do
        local project_label
        project_label=$(basename "$PROJECT_DIR")

        header "Managing: ${project_label}"

        local options=(
            "── Sections ──"
            "Add section"
            "Rename section"
            "Remove section"
            "Reorder sections"
            "── Files ──"
            "Add file"
            "Edit file"
            "Rename file"
            "Move file"
            "Delete file"
            "── Site ──"
            "Edit homepage"
            "Edit astro.config.mjs"
        )

        [[ $HAS_TREE -eq 1 ]] && options+=("View site structure")

        options+=("── ──" "Switch project" "Quit")

        local choice
        choice=$(printf '%s\n' "${options[@]}" | gum choose \
            --header "What would you like to do?" \
            --height 20) || true

        [[ -z "$choice" ]] && break

        case "$choice" in
            "Add section")            add_section ;;
            "Rename section")         rename_section ;;
            "Remove section")         remove_section ;;
            "Reorder sections")       reorder_sections ;;
            "Add file")               add_file ;;
            "Edit file")              edit_file ;;
            "Rename file")            rename_file ;;
            "Move file")              move_file ;;
            "Delete file")            delete_file ;;
            "Edit homepage")          edit_homepage ;;
            "Edit astro.config.mjs")  edit_config ;;
            "View site structure")    view_structure ;;
            "Switch project")
                return_to_origin
                return   # Back to main loop — will show project list
                ;;
            "Quit") break ;;
            "── "*) continue ;;  # Section headers — not selectable
        esac
    done
}

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    preflight_checks

    gum style \
        --foreground "$CYAN" --border-foreground "$CYAN" --border double \
        --align center --width 60 --margin "1 2" --padding "1 4" \
        'Starlight Manager'

    while true; do
        return_to_origin

        local project_list
        project_list=$(scan_projects)

        if [[ -z "$project_list" ]]; then
            gum style \
                --foreground "$YELLOW" --border-foreground "$YELLOW" --border rounded \
                --align center --width 60 --margin "1 2" --padding "1 2" \
                "No Starlight projects found in this directory tree."

            local choice
            choice=$(gum choose \
                "Create new project" \
                "Refresh" \
                "Quit" \
                --header "What would you like to do?") || true

            case "$choice" in
                "Create new project") create_project_flow ;;
                "Refresh")            continue ;;
                "Quit"|"")            break ;;
            esac
            continue
        fi

        # Build menu: create option + found projects + quit
        local menu_items=("── create new project ──")
        while IFS= read -r proj; do
            menu_items+=("$proj")
        done <<< "$project_list"
        menu_items+=("── quit ──")

        local selection
        selection=$(printf '%s\n' "${menu_items[@]}" | gum choose \
            --header "Select a project ($(echo "$project_list" | wc -l | tr -d ' ') found):") || true

        case "$selection" in
            "── create new project ──")
                create_project_flow
                ;;
            "── quit ──"|"")
                break
                ;;
            *)
                # Resolve to absolute path
                local abs_path
                if [[ "$selection" == "." ]]; then
                    abs_path="$ORIGIN_DIR"
                else
                    abs_path="${ORIGIN_DIR}/${selection}"
                fi

                if [[ ! -d "$abs_path" ]]; then
                    warn "Directory '${selection}' no longer exists."
                    continue
                fi

                if [[ ! -f "${abs_path}/${CONFIG_FILE}" ]]; then
                    warn "'${selection}' is no longer a valid Starlight project."
                    continue
                fi

                PROJECT_DIR="$abs_path"
                manage_menu
                ;;
        esac
    done

    echo ""
    success "Done. Run 'bash init.sh' inside your project to preview changes."
}

main "$@"
