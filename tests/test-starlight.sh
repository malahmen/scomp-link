#!/usr/bin/env bash
# The Starlight front-end, driven through the gum stub. No network: npm, node,
# mise and vim are stubs, so this checks what the TUI generates, not Astro
# itself (a real `npm run build` of both kinds of site was verified by hand).
#
# What it protects:
#   - sites over an existing folder: the documents are read in place, the
#     folder is never written to, and the site cannot be created inside it;
#   - sidebar groups use the Starlight 0.39+ shape, and old ones are migrated;
#   - Mermaid uses Astro 7's unified() processor and installs its package.
# shellcheck disable=SC2016
# Single-quoted heredoc stubs expand their own $1/$@ at run time, on purpose.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONT="${TEST_DIR}/../scripts/starlight/starlight_astro.sh"
[[ -f "$FRONT" ]] || { echo "front-end not found at $FRONT" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { grep -qF -- "$1" "$2"; }
lacks() { ! grep -qF -- "$1" "$2"; }

# ---- stubs: npm scaffolds a minimal Starlight tree, everything else records ----
mkdir -p "$T/bin"
cat > "$T/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$NPM_LOG"
if [[ "${1:-}" == create ]]; then          # npm create astro@latest <dir> -- ...
    d="$3"; mkdir -p "$d/src/content/docs/guides" "$d/src/content/docs/reference"
    echo '{ "name": "x" }' > "$d/package.json"
    echo '---' > "$d/src/content/docs/index.mdx"
    echo "export default {};" > "$d/astro.config.mjs"
fi
exit 0
EOF
cat > "$T/bin/node" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"[0]"*) printf 22 ;; *"[1]"*) printf 12 ;; *) echo v22.12.0 ;; esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/mise"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/vim"
chmod +x "$T/bin/"*
# A stand-in holo-convert engine, so Create never asks to clone one.
mkdir -p "$T/hc/.fcc"; : > "$T/hc/holo-convert.sh"

export PATH="${TEST_DIR}/stubs:$T/bin:$PATH"
export GUM_ANSWERS="$T/answers" GUM_STATE="$T/state" NPM_LOG="$T/npm.log"
export SCOMP_STARLIGHT_HOME="$T/home" HOLO_CONVERT_DIR="$T/hc"
# Never the real ~/.config/scomp-link/starlight-projects.
export SCOMP_STARLIGHT_REGISTRY="$T/registry"

# run <cwd> <answer>... — run the TUI from <cwd> with scripted gum answers.
run() {
    local cwd="$1"; shift
    printf '%s\n' "$@" > "$GUM_ANSWERS"; : > "$GUM_STATE"; : > "$NPM_LOG"
    (cd "$cwd" && bash "$FRONT") > "$T/out" 2>&1
}

# ---- a folder of documents to serve ------------------------------------------
SRC="$T/docs-repo"; mkdir -p "$SRC/sub"
printf '# Readme\n\nSee [a](a.md).\n' > "$SRC/README.md"
printf -- '---\ntitle: "A"\n---\n\n## Body\n' > "$SRC/a.md"
printf '# Deep\n' > "$SRC/sub/b.md"
before="$(find "$SRC" -type f | sort | xargs cat | cksum)"
mkdir -p "$T/start"

echo "# 1. site over an existing folder, created outside any repository"
run "$T/start" \
    "Create site over an existing folder" "$SRC" "Reports" "" \
    "$T/home/reports  (scomp-link's sites folder)" \
    "Quit" "── quit ──"
P="$T/home/reports"
check "project created under STARLIGHT_HOME" test -f "$P/package.json"
check ".docs-source holds the absolute source path" [ "$(cat "$P/.docs-source" 2>/dev/null)" = "$SRC" ]
check "the template's own pages are gone" test ! -e "$P/src/content/docs"
check "content collection loads from the external folder" has "loader: externalDocs(DOCS_SOURCE)" "$P/src/content.config.ts"
check "README becomes the homepage (docId)" has "if (id === 'readme') return 'index';" "$P/src/external-docs.mjs"
check "astro.config uses the unified() processor with both plugins" \
    has "processor: unified({ remarkPlugins: [remarkDropLeadingH1, remarkMdLinksToPages] })" "$P/astro.config.mjs"
check "dev server may read the source folder" has "allow: ['.', DOCS_SOURCE]" "$P/astro.config.mjs"
check "@astrojs/markdown-remark installed" has "npm install @astrojs/markdown-remark" "$NPM_LOG"
check "the source folder is untouched" [ "$(find "$SRC" -type f | sort | xargs cat | cksum)" = "$before" ]
check "no project files written into the source" test ! -e "$SRC/package.json"
check "the external menu was shown" has "(external)" "$T/out"

echo "# 2. the site is listed again from STARLIGHT_HOME, by absolute path"
run "$T/start" "── quit ──"
# The list is piped into gum choose, which the stub doesn't echo; the header
# carries the count, and selecting the absolute path must open the site.
check "external site counted in the project list" has "Select a project (1 found)" "$T/out"
run "$T/start" "$P" "Quit" "── quit ──"
check "selecting it by absolute path opens the external menu" has "(external)" "$T/out"

echo "# 3. refuses to create the site inside the source folder"
run "$SRC" \
    "── create site over an existing folder ──" "$SRC" "Inside" "" \
    "$SRC/inside  (here)" "── quit ──"
check "refusal explained" has "overlaps the source folder" "$T/out"
check "nothing created inside the source" test ! -e "$SRC/inside"
check "npm never ran" test ! -s "$NPM_LOG"

echo "# 4. normal project: new sidebar shape, Mermaid on Astro 7's processor"
run "$T/start" \
    "── create new project ──" "Docs Test" "$T/start/docs-test  (here)" "" "yes" \
    "guides" "Guides" "autogenerate" "" \
    "" \
    "Back to project list" "── quit ──"
N="$T/start/docs-test"
check "autogenerate group in the 0.39+ shape" \
    has "{ label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] }" "$N/astro.config.mjs"
check "no old-shape group written" lacks "', autogenerate: {" "$N/astro.config.mjs"
check "Mermaid passed to unified()" has "processor: unified({ remarkPlugins: [remarkMermaid] })" "$N/astro.config.mjs"
check "Mermaid installs @astrojs/markdown-remark" has "npm install @astrojs/markdown-remark" "$NPM_LOG"

echo "# 5. an old-shape sidebar is migrated on open (only when accepted)"
cat > "$N/astro.config.mjs" <<'EOF'
      sidebar: [
        { label: 'Guides', autogenerate: { directory: 'guides' } },
        { label: 'Deep Docs', autogenerate: { directory: 'deep/docs' } }
      ],
EOF
cp "$N/astro.config.mjs" "$T/old.mjs"
run "$T/start" "docs-test" "no" "Quit" "── quit ──"
check "declined: config left as is" cmp -s "$N/astro.config.mjs" "$T/old.mjs"
run "$T/start" "docs-test" "yes" "Quit" "── quit ──"
check "accepted: first group converted" \
    has "{ label: 'Guides', items: [{ autogenerate: { directory: 'guides' } }] }," "$N/astro.config.mjs"
check "accepted: nested directory converted" \
    has "{ label: 'Deep Docs', items: [{ autogenerate: { directory: 'deep/docs' } }] }" "$N/astro.config.mjs"
check "accepted: no old shape left" lacks "', autogenerate: {" "$N/astro.config.mjs"

echo "# 6. deleting an external site: name and confirm gate it; the source survives"
run "$T/start" "$P" "Delete this site" "wrong-name" "Quit" "── quit ──"
check "wrong name: site kept" test -d "$P"
check "wrong name: explained" has "Name did not match" "$T/out"
run "$T/start" "$P" "Delete this site" "reports" "no" "Quit" "── quit ──"
check "declined: site kept" test -d "$P"
check "the warning says the source is not touched" has "The source folder is NOT touched: $SRC" "$T/out"
run "$T/start" "$P" "Delete this site" "reports" "yes" "── quit ──"
check "confirmed: site deleted" test ! -e "$P"
check "confirmed: site forgotten from the registry" lacks "$P" "$SCOMP_STARLIGHT_REGISTRY"
check "confirmed: the source folder is untouched" [ "$(find "$SRC" -type f | sort | xargs cat | cksum)" = "$before" ]

echo "# 7. refuses when the source folder lives inside the site"
mkdir -p "$T/home/inner/docs" && echo "x" > "$T/home/inner/docs/x.md"
echo '{}' > "$T/home/inner/package.json"; echo "export default {};" > "$T/home/inner/astro.config.mjs"
echo "$T/home/inner/docs" > "$T/home/inner/.docs-source"
run "$T/start" "$T/home/inner" "Delete this site" "Quit" "── quit ──"
check "refused, documents inside the site" has "would delete the documents" "$T/out"
check "nothing deleted" test -f "$T/home/inner/docs/x.md"
rm -rf "${T:?}/home/inner"     # fixture only; later cases count listed projects

echo "# 8. refuses the project the TUI was started from"
run "$N" "." "Delete this project" "Quit" "── quit ──"
check "refused: it is the start directory" has "this TUI was started from" "$T/out"
check "start-directory project kept" test -f "$N/package.json"

echo "# 9. deleting a normal project warns that its pages go with it"
run "$T/start" "docs-test" "Delete this project" "docs-test" "yes" "── quit ──"
check "pages-go-too warning shown" has "page(s) under src/content/docs/ go too" "$T/out"
check "normal project deleted" test ! -e "$N"

echo "# 10. open by path: any Astro config name, remembered and listed from anywhere"
O="$T/elsewhere/team-docs"; mkdir -p "$O/src/content/docs"
echo '{}' > "$O/package.json"; echo "export default {};" > "$O/astro.config.ts"
run "$T/start" "Open a project by path…" "$O" "Quit" "── quit ──"   # no projects yet: the empty-state menu
check "astro.config.ts project opened" has "Managing: team-docs" "$T/out"
check "remembered in the registry" has "$(cd "$O" && pwd -P)" "$SCOMP_STARLIGHT_REGISTRY"
mkdir -p "$T/other"
run "$T/other" "── quit ──"
check "listed from an unrelated start directory" has "Select a project (1 found)" "$T/out"
run "$T/other" "$(cd "$O" && pwd -P)" "Quit" "── quit ──"
check "selecting it by path opens it" has "Managing: team-docs" "$T/out"

echo "# 11. open by path refuses a folder without an Astro config"
mkdir -p "$T/not-a-site"
run "$T/other" "── open a project by path… ──" "$T/not-a-site" "── quit ──"
check "refusal explained" has "No Astro config" "$T/out"
check "not remembered" lacks "$T/not-a-site" "$SCOMP_STARLIGHT_REGISTRY"

echo "# 12. a remembered project that disappeared is hidden, not forgotten"
echo "$T/gone-away" >> "$SCOMP_STARLIGHT_REGISTRY"
run "$T/other" "── quit ──"
check "still 1 project listed" has "Select a project (1 found)" "$T/out"
check "the missing entry is kept" has "$T/gone-away" "$SCOMP_STARLIGHT_REGISTRY"

echo "# 13. delete refuses the start directory even through a symlink"
ln -s "$O" "$T/link-to-team-docs"
run "$T/link-to-team-docs" "$(cd "$O" && pwd -P)" "Delete this project" "Quit" "── quit ──"
check "refused via the real path" has "this TUI was started from" "$T/out"
check "project kept" test -f "$O/package.json"

echo "# 14. 'Another folder…': any folder, created on confirm"
run "$T/other" "── create site over an existing folder ──" "$SRC" "Sites Elsewhere" "" \
    "Another folder…" "$T/my-sites/new" "yes" "Quit" "── quit ──"
check "site created in the chosen folder" test -f "$T/my-sites/new/sites-elsewhere/package.json"
check "and served from the source in place" [ "$(cat "$T/my-sites/new/sites-elsewhere/.docs-source")" = "$SRC" ]

echo "# 15. a location inside a git repository is warned about"
mkdir -p "$T/some-repo" && git -C "$T/some-repo" init -q
run "$T/other" "── create new project ──" "In Repo" "Another folder…" "$T/some-repo" "no" "── quit ──"
check "warning names the repository" has "inside the git repository $T/some-repo" "$T/out"
check "declined: nothing created" test ! -e "$T/some-repo/in-repo"
run "$T/other" "── create new project ──" "In Repo" "Another folder…" "$T/some-repo" "yes" \
    "" "no" "" "" "Back to project list" "── quit ──"
check "accepted: created inside the repository" test -f "$T/some-repo/in-repo/package.json"

echo "# 16. a location that would contain the source folder is refused"
run "$T/other" "── create site over an existing folder ──" "$SRC/sub" "docs-repo" "" \
    "Another folder…" "$T" "── quit ──"
check "overlap refused" has "overlaps the source folder" "$T/out"
check "nothing created around the source" test ! -e "$T/docs-repo/package.json"

echo; if (( FAILS == 0 )); then echo "all passed"; else echo "${FAILS} failed"; exit 1; fi
