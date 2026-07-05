# k9s

`k9s/k9s.sh`

Install and launch [k9s](https://k9scli.io) - a terminal UI for Kubernetes.

- No config file of its own, k9s reads the ambient kubeconfig exactly like `kubectl` does
- `launch` picks a context explicitly (via k9s's own `--context` flag) instead of silently relying on kubectl's `current-context`, auto-selects if there's only one context, otherwise prompts. Never mutates your ambient kubectl state.
- Install/uninstall via `mise use --global` / `mise uninstall --all` (same pattern `setup.sh` uses for `gum`)
- Commands: `install`, `uninstall`, `status`, `launch`
