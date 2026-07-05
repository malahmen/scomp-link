# SSH Profile Manager

`ssh/sshger.sh`

Manage SSH connection profiles directly in `~/.ssh/config`. The script owns a delimited managed section (between `# BEGIN sshger` / `# END sshger` markers); everything outside that section is left untouched, and existing unmanaged hosts can be imported.

**Actions:**

- **add**: create a profile, generate a new `ed25519` / `rsa-4096` key (or reuse an existing one), and copy the public key to the clipboard
- **import**: pull existing `Host` entries from outside the managed section into management, optionally removing the originals
- **remove**: delete a profile (optionally its key files too)
- **view**: show profile details and the public key
- **edit**: change host / hostname / user / port / key path
- **use**: wire a profile to the current git repo (rewrites `origin` URL, optionally sets local `user.name` / `user.email`)
- **test**: verify the SSH connection for a profile (single host or all hosts)
- **list**: show all managed profiles

**Dependencies:** `jq` (prompted on first run if missing).
