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
| **Self-signed certificate** | Creates a CA and signs the cert with it | `-d -s 1 -n -t -c (-i\|-f) [-a] [-E -p]` |
| **Convert .crt → .cert/.pem** | Builds `.cert` (and `.pem` with the key) from an existing `.crt` | `-d -r [-k]` |
| **Certificate request (CSR)** | Key + CSR to send to a CA | `-d -s 0 -n (-i\|-f)` |
| **Protect an existing CA key** | Moves `ca.key` into the engine's `0700` `ca-private/` directory | `-R -o` |

For self-signed and CSR you pick a **subject source**: a subject string (`-i`, e.g.
`/C=PT/O=Acme/CN=example.com`) or an `openssl` config file (`-f`).

### Two validity questions, not one

Self-signed now asks twice, because the engine separated them:

- **Leaf validity**, default **398** days. The front-end used to offer 3650,
  which was the engine's default for both certificates at the time. Apple
  platforms refuse any certificate issued after 2019-07-01 with a lifetime over
  825 days *whatever root signed it*, so that default quietly produced
  certificates macOS and iOS will not accept.
- **CA validity**, default **3650**. A root is long-lived on purpose:
  shortening it does not reduce what a leaked key can do, it only means
  re-distributing the anchor to every machine and browser profile that trusts
  it.

### The CA key

Self-signed also offers to **encrypt the CA key** (AES-256, `-E`). It asks for
the **path to a file** holding the passphrase, never the passphrase itself —
the engine has no flag that takes one, because `argv` is readable by every
process on the machine for as long as `openssl` runs.

Say no and the CA key is created unencrypted, with the engine's warning. Say
yes without naming a file and the front-end drops `-E` rather than running
something that half-applies it. A passphrase is only worth having if that file
lives somewhere the CA key does not.

A new CA puts its key in `<output>/ca-private/ca.key` (mode `0600`, in a `0700`
directory); the CA **certificate** stays at `<output>/ca.crt`, because it is
public and other things read it by path. **Protect an existing CA key** is the
menu entry for a CA made before that: it moves the key and leaves `ca.crt`
alone. It is separate from the certificate modes on purpose — the engine will
not move somebody's CA key as a side effect of issuing a certificate.

## Output

Generated files are written to **`./certificates/`** in the directory you launched
from (the engine never writes into its own install location). After a successful run
the front-end opens that folder.

## Driving the engine directly

You can skip the TUI and call the engine yourself:

```sh
ignite.sh -d example.com -i "/C=PT/O=Acme/CN=example.com" -a "/C=PT/O=Acme/CN=Acme Root CA" -t 365
ignite.sh -d example.com -g 1          # config template
ignite.sh -R -o ~/.local/share/kuat-pki   # move an existing CA key to ca-private/
ignite.sh -h                           # all options
```

See the [engine README](https://github.com/malahmen/younglings-key) for the full flag
reference.
