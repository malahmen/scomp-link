# younglings-key (certificate generation)

`younglings-key/younglings-key.sh`

A gum front-end for **[younglings-key](https://github.com/malahmen/younglings-key)**,
a standalone, gum-free certificate engine (`ignite.sh`, a flag-driven wrapper around
`openssl`). scomp-link ships only the interactive front-end, auto-discovered in the
launcher like any other script; the generation logic lives in the engine's own repo —
the same split as [holo-convert](holo-convert.md).

## Engine resolution

The front-end finds `ignite.sh` automatically, in order:

1. `$YOUNGLINGS_KEY_DIR/ignite.sh` (explicit override)
2. `../../../younglings-key/ignite.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/younglings-key/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo

## Requirements

- **`openssl`** — the engine's only dependency. If missing, the front-end offers to
  install it (Homebrew / apt / dnf) before running.
- `gum`, `git` (framework floor).

## Modes

The menu lists them in a typical workflow order (prepare a config → make a cert
locally → post-process it → request one from a real CA):

| Mode | What it does | Engine flags |
| ---- | ------------ | ------------ |
| **Config template (.cfg)** | Writes an editable `openssl` config for the domain | `-d -g 1 -n` |
| **Self-signed certificate** | Creates a CA and signs the cert with it | `-d -s 1 -n -t (-i\|-f) [-a]` |
| **Convert .crt → .cert/.pem** | Builds `.cert` (and `.pem` with the key) from an existing `.crt` | `-d -r [-k]` |
| **Certificate request (CSR)** | Key + CSR to send to a CA | `-d -s 0 -n (-i\|-f)` |

For self-signed and CSR you pick a **subject source**: a subject string (`-i`, e.g.
`/C=PT/O=Acme/CN=example.com`) or an `openssl` config file (`-f`).

## Output

Generated files are written to **`./certificates/`** in the directory you launched
from (the engine never writes into its own install location). After a successful run
the front-end opens that folder.

## Driving the engine directly

You can skip the TUI and call the engine yourself:

```sh
ignite.sh -d example.com -i "/C=PT/O=Acme/CN=example.com" -a "/C=PT/O=Acme/CN=Acme Root CA" -t 365
ignite.sh -d example.com -g 1          # config template
ignite.sh -h                           # all options
```

See the [engine README](https://github.com/malahmen/younglings-key) for the full flag
reference.
