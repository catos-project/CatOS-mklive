# Cross-file findings

Things that fell out of reading the actual scripts, not obvious from any
single file in isolation — relevant when touching them.

- **`display-manager-autologin.sh` is the actual source of truth for "what
  desktop shows up after boot,"** not any single build-time flag. It runs
  unconditionally, and SDDM's block **hardcodes `Session=plasma.desktop`**
  regardless of which DE was actually installed by `mkiso.sh -b <variant>`.
  See [dracut-modules.md](dracut-modules.md) § display-manager-autologin.sh.
- `mklive.sh` and `mkiso.sh` each carry local `mount_pseudofs`/
  `umount_pseudofs` overrides that shadow (and have drifted from) `lib.sh`'s
  versions of the same functions.
- `mkplatformfs.sh` does **not** source `platforms/*.sh` — despite the
  naming, it's `mklive.sh -P` that sources platform files. Adding a new
  board means editing `lib.sh`'s `set_target_arch_from_platform` map, not
  just adding a file under `platforms/`.
- `mknet.sh` copies `installer.sh` into the netmenu dracut module without
  the `@@MKLIVE_VERSION@@` templating step that `mkiso.sh` performs, so a
  PXE-launched installer session shows the literal placeholder string
  instead of a version.
- `packer/` and `container/` are unrelated side paths: Packer builds boot
  the *official upstream Void ISO* (not anything `mklive.sh` produces), and
  `container/` is a build-environment container for *running* mklive.sh, not
  a container image of CatOS itself.
- `keys/*.plist` are stock upstream Void xbps signing keys, not CatOS-specific.
- `version` (top-level file) is CatOS-mklive's own build-tool version —
  only ever read (via `lib.sh`), never written by any script, unrelated to
  the OS's own `os-release` version.
- `branding/` currently contains only a `README.md` explaining the overlay
  mechanism (`-I` flag) — no actual `os-release`, motd, or wallpaper files
  exist yet. See [branding-and-outputs.md](branding-and-outputs.md).
