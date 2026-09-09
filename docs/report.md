# Documentation-vs-scripts review — follow-up report

Date: 2026-09-09. Companion to the working-tree changes made the same day (49 files, uncommitted on `master`). Everything below is what was **not** done in that pass: test runs that need a real host, script fixes that were out of scope for a documentation pass, and repo hygiene. Line numbers refer to the current working tree.

## 1. Test runs required before committing

| What | How | Pass criterion |
| --- | --- | --- |
| LGTM Docker target | `lgtm.sh` → Docker → install with all components; then `docker logs` for `lgtm_loki`, `lgtm_tempo`, `lgtm_mimir`, `lgtm_otelcol`, `lgtm_grafana` | All five stay up; Grafana at :3000 shows Mimir/Loki/Tempo datasources. Keys most likely to be rejected: Mimir 3.x `memberlist.join_members: []`, `usage_stats.enabled`, `store_gateway.sharding_ring.replication_factor`; Loki `ruler:` block (drop it if it complains); Tempo `compactor.compaction.block_retention`, `usage_report.reporting_enabled`. |
| LGTM re-install | Run install again | Every config logs `keeping existing …`; nothing overwritten. |
| MongoDB Docker app user | Install with a **new** container name, then `connect` | Connect logs in as the app user against the app database. Init scripts only run on an empty volume, so an existing volume will not get the user (the script warns). |
| MongoDB K8s connect | `connect` as root, then as the app user | Root works with auth db `admin`; app user works with auth db = app database (the groundhog2k chart creates it there, `templates/scripts.yaml`). |
| Export of the two WoW front-ends | `./export.sh wow-nordrassil /tmp/x && bash /tmp/x/wow-nordrassil.sh` (same for wow-dark-portal) | Script starts standalone; previously it failed on `../_common/ui.sh`. |
| influxdb K8s connect | `connect` on a K8s target | Port-forward now goes through `_k8s_start_port_forward`; tunnel comes up. |
| README render | Preview README.md | Tables render (cell counts were checked: 2- and 3-column tables only). |

## 2. Pending script fixes (found in review, not applied)

Ordered by impact.

1. **`nc` is a silent hard dependency.** Every K8s port-forward/connect readiness loop calls `nc -z` and none checks for it: postgres 455/506, mariadb 501/551, mysql 476/526, mongodb 516/566, redis 640/678/722, qdrant 496/532, influxdb 556, prometheus 312, grafana 740, harbor 437, n8n 563, argo 250/480/834. Without `nc` the loops time out with a misleading "port-forward did not become ready". Fix: add `_check_nc` (or a `_wait_port` helper using bash `/dev/tcp` as fallback) to `scripts/_common/deps.sh` and call it from those paths.
2. **`docker-compose` v1 binary assumed.** `lgtm.sh` and `dozzle.sh` shell out to `docker-compose`; current Docker ships the `docker compose` v2 plugin. Neither script checks for the binary (`_check_docker` only checks `docker`). Fix: resolve a `COMPOSE` command once (`docker compose` if `docker compose version` works, else `docker-compose`) in `deps.sh` and use it in both.
3. **dozzle stale-config risk.** `dozzle.sh:92` sources an existing `dozzle.conf` verbatim, and `uninstall` runs `rm -rf "$STORAGE_PATH"` (`:631`). A conf written by an older version with a literal `~` path (see §4) would delete a path relative to the CWD. Fix: normalise `STORAGE_PATH` after sourcing (expand a leading `~`, refuse relative paths).
4. **Unguarded `lsof` / `curl`.** `lgtm.sh:1499` and `dozzle.sh:832` call `lsof` for port checks with no fallback (kind.sh falls back to `ss`). `qdrant.sh:210` and `influxdb.sh:226,275` call `curl` unguarded in Docker readiness/status. `argo.sh` uses `base64` unguarded (`:506`).
5. **Export manifests missing runtime deps.** `karpenter.sh:4` declares `kubectl kind` but hard-requires `go` and `git` (both installable via mise); `lazygit.sh:4` omits `git`. The five engine front-ends and both WoW front-ends ship floor-only exports and rely on runtime checks for `git`, `jq`, `openssl`; that is by design but worth a `# export-setup: git` on each.
6. **redis.sh Bitnami leftover.** `redis.sh:508-513` probes `svc/<release>-master` (Bitnami naming) before falling back to `svc/<release>`; the groundhog2k chart never creates `-master`. Safe to remove.
7. **lgtm.sh minor logic gaps.** kind prompts for a hostPath base (`:328-337`) it never uses (`:866`); default component pre-selection omits otelcol (`:381`) although `test` requires it (`:1681-1687`); a saved `custom` profile cannot be restored on re-install (`:979-981`). Tempo and Mimir use named volumes rather than bind mounts under `${data_path}` (deliberate: the images run as uid 10001 and cannot write host-owned bind mounts without a `user:` override); decide whether that is the wanted layout.
8. **dozzle `templates/k8s/pv-hostpath.yaml`** lacks `type: DirectoryOrCreate`, unlike the harbor/lgtm hostPath PVs. First deploy on a node without the directory fails to mount.
9. **Linux-only scripts have no guard.** `bazzite-utils.sh` (header says Linux-only), `clone-army.sh` (GNU `find -printf`, X11 tools, `declare -A` needs bash 4) and `docker.sh` (systemctl) only fail indirectly on macOS. comfyengine/gameconqueror have `_require_linux`; reuse it.
10. **bmad.sh dependency check coverage.** `python3` is required by the registry code used by List/Delete (`:137`) but only Create/Update call `require_bmad_deps` (`:230,262`). Python < 3.10 only warns (`:114`).
11. **n8n timezone on K8s.** `GENERIC_TIMEZONE` is prompted and applied on Docker only (`n8n.sh:184-188,225`); the Helm path ignores it. Either pass it via chart values or skip the prompt on K8s.
12. **Engine front-ends: `--setup` on failure.** Only holo-convert offers the engine's `--setup` and retries (`holo-convert.sh:380-385`). protocol-droid, younglings-key, navicomputer, mind-trick do not follow the template's pattern. Documented as-is in `docs/engine-split-candidates.md:47`; implement if the pattern matters.
13. **Init.sh / export.sh dead exclusion.** `EXCLUDED_DIRS` in `init.sh:24` and the `! -path "*/cluster/*"` in `export.sh` exclude a `scripts/cluster/` folder that no longer exists. Harmless; drop for clarity.
14. **MongoDB app password in container env.** The Docker fix stores `SCOMP_APP_PASSWORD` in the container env, same exposure as the pre-existing `MONGO_INITDB_ROOT_PASSWORD`. If that matters, switch both to a bind-mounted credentials file read by `connect`.

## 3. Documentation nits left as-is

- k9s.md: the interactive menu is state-dependent (only `install` when absent; `launch/status/uninstall` when present). Not mentioned.
- akinn.md: "a selection always validates" is not true for the fallback paths (bare semver tags, free-text input when the fetch fails) at `akinn_tui.sh:128-136,149-151`.
- README Quick Start still has the `your-username` clone URL and the License placeholder.
- README Infra/DB tables use bare `script.sh` while Gaming/Utilities use `folder/script.sh`. Consistent within each table now, not across tables.

## 4. Repo hygiene (untracked, gitignored, safe to delete)

- `~/` at the repo root: `~/.config/{dozzle,gh,helm,lgtm}` created between March and June by an exported `XDG_CONFIG_HOME="~/.config"`; helm and gh honour that variable too, which is why their configs are there. The tilde guard has been in dozzle/lgtm since commit `57ae56d` and lmstudio since `f4ee4ee`, and `~/.zshrc` now exports the expanded path. Residual risk: the scripts do not re-export a normalised `XDG_CONFIG_HOME`, so if the environment regresses, helm/gh children will recreate `./~/.config/helm` in the CWD.
- `marker-output/` (output of the pre-split marker script), `output/vanilla-wow-client.pdf`, `.fcc/` at the root (a runtime working copy; the canonical assets live in the holo-convert engine).
- `.claude/settings.local.json:87` still allows `scripts/ssh/sshger.sh`, a path that no longer exists. Harmless.

## 5. What the same-day pass changed (for context)

- README, docs/export.md, docs/engine-split-candidates.md, 27 docs under docs/scripts/, setup.sh comments, export.sh comment, `_templates/engine-frontend.sh` (vendor-aware sourcing).
- Scripts: mongodb.sh (Docker app-user init script, app-user connect, K8s auth-database prompt), lgtm.sh (`_write_docker_configs` + two compose fixes), influxdb.sh (use `_k8s_start_port_forward`, optional python3), wow-nordrassil.sh and wow-dark-portal.sh (vendor-aware sourcing, export note), redis.sh / clone-army.sh / karpenter.sh / starlight_astro.sh / convert.sh (comments and messages), argo.sh description header, eleven `# Sources:` header lines.
- All modified scripts pass `bash -n`. Nothing committed.
