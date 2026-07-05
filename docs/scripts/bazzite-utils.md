# Bazzite Utils

`bazzite-utils/bazzite-utils.sh`

Grab-bag of gaming-on-Linux workaround utilities, named after [Bazzite](https://bazzite.gg/) (the primary target) but works on any dnf/apt/rpm-ostree host.

- **`ea-fix`**: copies EA App's staged self-update into place under Wine/Proton (EA's own updater frequently stages an update it never applies). The Wine/Proton prefix path is prompted once and persisted.
- **`ubisoft-rws`**: finds Ubisoft Connect windows that render off-screen or invisible under Wine/Proton and repositions/raises them
- Commands: `ea-fix`, `ubisoft-rws`
