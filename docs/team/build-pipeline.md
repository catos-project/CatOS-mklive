# CatOS-mklive build pipeline

CatOS-mklive is a fork of Void Linux's `void-mklive`. All output is built from
Void's binary package repository (xbps) — nothing here compiles a distro from
source. The scripts assemble rootfs trees with `xbps-install`, then package
them into ISOs, tarballs, or disk images. "CatOS" branding is layered on top
of stock Void output via `-I ./branding` (see `mkiso.sh`) and `data/issue`,
not by patching these scripts.

## Pipeline overview

```
lib.sh                     shared shell functions, sourced by every script below
  |
  +-- mkrootfs.sh  --------> void-<arch>-ROOTFS-<date>.tar.xz
  |         |                (plain Void userland, no kernel, no bootloader)
  |         |
  |         +-- mkplatformfs.sh --> void-<platform>-PLATFORMFS-<date>.tar.xz
  |         |         (expands a ROOTFS tarball, adds kernel + platform pkgs)
  |         |         |
  |         |         +-- mkimage.sh --> void-<platform>-<date>.img.xz / .tar.gz
  |         |         |         (partitions a disk image, unpacks PLATFORMFS, installs bootloader)
  |         |         |
  |         +-- mknet.sh -------> void-<arch>-NETBOOT-<date>.tar.gz
  |                   (adds kernel + dracut netmenu/autoinstaller directly to a ROOTFS)
  |
  +-- mklive.sh  (standalone) --> void-live-<arch>-<kver>-<date>.iso
            |    (basic live ISO: installs base-system + kernel, builds
            |     initramfs, isolinux+grub, squashfs, xorriso)
            |
            +-- mkiso.sh (wraps mklive.sh, one call per desktop variant)
                      --> void-live-<arch>-<date>-<variant>.iso
                      (adds void-installer, desktop pkgs/services, pipewire,
                       lightdm session config, via -I <tmpdir> overlay)

installer.sh   — the interactive dialog(1) installer ("void-installer").
                 Not run standalone; it's baked into live ISOs by mkiso.sh
                 and into netboot images by mknet.sh.

setup.sh       — one-time host bootstrap (installs xbps-static + host tools),
                 not part of the image-build pipeline itself.

Makefile       — orchestrates all of the above for batch/CI builds
                 (targets: live-iso-all, rootfs-all, platformfs-all,
                 images-all, pxe-all, wsl-all, dist, checksum).

release.sh     — does not build anything locally; triggers the Makefile-driven
                 GitHub Actions workflow (gen-images.yml) via `gh workflow run`,
                 downloads finished artifacts, and signs checksums with minisign.

version        — top-level file containing a bare version string (currently
                 "0.26"). Read (never written) by lib.sh's version() function,
                 combined with `git rev-parse --short HEAD` for `-V` output on
                 every script. Nothing in this repo bumps it automatically.
```

Root privilege is required for every script that touches a rootfs
(`mkrootfs.sh`, `mkplatformfs.sh`, `mklive.sh`, `mkimage.sh`, `mknet.sh`) because
they bind-mount `/dev /proc /sys`, chroot, and use loop devices. `mkiso.sh` and
`release.sh` don't check for root themselves — they either exec a script that
checks (`mklive.sh`) or never touch a rootfs (`release.sh`).

---

## lib.sh

Purpose: shared function library, sourced (`. ./lib.sh`) by every other script
here except `installer.sh`. Not standalone.

Key functions:
- `version()` — prints `$PROGNAME <contents of ./version> <git short rev>`.
  Backs every script's `-V` flag.
- `is_target_native(arch)` — decides whether the target arch can run without
  QEMU on this host (handles i686-on-x86_64, armv*-on-aarch64, ppc-on-ppc64,
  etc.).
- `check_tools()` — verifies `$LIBTOOLS` (fixed list: cp, echo, cat, printf,
  which, mountpoint, mount, umount, modprobe) plus each script's own
  `$REQTOOLS` are on PATH; prints resolved paths. Dies if anything is missing.
- `mount_pseudofs` / `umount_pseudofs` — bind-mount/unmount `dev proc sys` (and
  a tmpfs at `tmp`) under `$ROOTFS`. **Idempotent by design** — always checks
  `mountpoint -q` first. `mkiso.sh` and `mklive.sh` each define their own
  local overrides of these two functions instead of using lib.sh's (they mount
  only `sys dev proc`, no tmp tmpfs) — don't assume the lib.sh version is what
  runs in those two scripts.
- `run_cmd_target` — runs a command with either `XBPS_ARCH` (native target) or
  `XBPS_TARGET_ARCH` (foreign target) set, per `is_target_native`.
- `run_cmd` — just logs and `eval`s a command (used for the tar|xz pipelines
  so the user can see the exact command line).
- `run_cmd_chroot(dir, cmd)` — calls `register_binfmt`, `mount_pseudofs`, then
  `chroot "$dir" sh -c "$cmd"`.
- `register_binfmt()` — sets up `qemu-<cpu>` under `binfmt_misc` for foreign
  architectures. No-op if `$XBPS_TARGET_ARCH` matches the host arch. Requires
  `update-binfmts` and a `qemu-<cpu>` binary to exist if crossing archs.
- `set_target_arch_from_platform()` — the **authoritative** platform→arch map
  (rpi-aarch64→aarch64, GCP→x86_64, pinebookpro→aarch64, asahi→aarch64, plus
  `-musl` suffix passthrough). `mkplatformfs.sh` and `Makefile`
  (`void-%-PLATFORMFS...: void-$$(shell ./lib.sh platform2arch %)-ROOTFS...`)
  both depend on this. **If you add a new platform, it must be added here**
  or `mkplatformfs.sh`/the Makefile's `.SECONDEXPANSION` rule cannot resolve
  its ROOTFS dependency.
- `die()` — prints `FATAL: ...`, calls `umount_pseudofs`, removes `$ROOTFS` if
  set, exits 1. Registered via `trap` in most scripts so interrupts clean up
  mounts instead of leaving the host in a broken state.
- Sourcing this file with `./lib.sh platform2arch <platform>` as argv (rather
  than sourcing it) prints the resolved arch and exits — this is how the
  Makefile's `.SECONDEXPANSION` rule for `mkplatformfs` targets gets the arch
  without duplicating the map.

Gotcha: `lib.sh` sets defaults for `XBPS_REPOSITORY` (Void's `current`,
`current/musl`, `current/aarch64` repos) at **source time**, unconditionally
appended. Every script that also builds its own `$XBPS_REPOSITORY` from `-r`
flags ends up with the default repos tacked on in addition to any custom `-r`
(see `mklive.sh` line ~534, `mkplatformfs.sh`, `mkrootfs.sh` via Makefile's
`XBPS_REPOSITORY` variable) — a custom `-r` supplements rather than replaces
the default Void repos.

---

## mklive.sh

Purpose: builds a minimal, bootable live ISO of Void Linux from packages —
the core image-building script. `mkiso.sh` is a thin wrapper around it.

Key CLI flags (`getopts "a:b:r:H:c:C:T:Kk:l:i:I:S:e:s:o:p:g:v:P:x:Vh"`):
- `-a <arch>` — target `XBPS_ARCH` (default: host arch via `xbps-uhelper arch`).
- `-b <system-pkg>` — base package installed into the image (default:
  `base-system`).
- `-r <repo>` — add an XBPS repository (repeatable; see lib.sh gotcha above).
- `-c` / `-H` — target / host XBPS cache dirs.
- `-i` — initramfs compressor (`lz4|gzip|bzip2|xz`, default xz).
- `-s` — squashfs compressor (`gzip|lzo|xz`, default xz).
- `-o <file>` — output ISO path (default: auto-generated from arch/kernel
  version/date, set at mklive.sh:669).
- `-p "<pkg> ..."` — extra packages, appended to `PACKAGE_LIST`.
- `-g "<pkg> ..."` — packages to *ignore* (`IGNORE_PKGS`); written as
  `ignorepkg=` lines into `$ROOTFS/etc/xbps.d/mklive-ignore.conf`.
- `-I <includedir>` — a directory whose contents are copied verbatim into the
  rootfs root (`copy_include_directories`, mklive.sh:210). This is how
  `mkiso.sh` injects the installer binary, lightdm session config, and
  pipewire autostart files; it's also the flag `mkiso.sh -- -I ./branding`
  (per `setup.sh`) uses to layer CatOS branding on top.
- `-S "<service> ..."` — extra runit services to symlink into
  `runsvdir/default`, in addition to the hardcoded
  `DEFAULT_SERVICE_LIST="agetty-tty1..6 udevd"` (mklive.sh:689). Dies if a
  named service doesn't exist under `/etc/sv` in the rootfs.
- `-b`/`-e <shell>` — change root's login shell via `chsh` in the chroot.
- `-C "<arg> ..."` — extra kernel command-line args (`BOOT_CMDLINE`), appended
  into both the isolinux and grub boot entries.
- `-P "<platform> ..."` — aarch64-only. Sources `platforms/<platform>.sh` for
  each named platform (only `pinebookpro` and `x13s` exist today) and adds a
  GRUB submenu with platform-specific kernel cmdline/DTB. Silently forced
  empty on x86_64/i686 (mklive.sh:560, `PLATFORMS=() # arm only`).
- `-T <title>` — `BOOT_TITLE` (default `"Void Linux"`). Substituted via `sed`
  into both `isolinux/isolinux.cfg.in` (`@@BOOT_TITLE@@` → menu label text)
  and `grub/grub_void.cfg.pre`-derived config (used to build each
  `menuentry` title string, e.g. `"${BOOT_TITLE} ${KERNELVERSION} (arch)"`,
  see `write_entries()` at mklive.sh:309). This is the flag to set for CatOS
  branding of the boot menu.
- `-v linux<version>` — pick a specific kernel: bare `linux`, a pinned
  `linux6.6.30`-style version, `linux-mainline`/`linux-lts` (queries the repo
  to resolve the actual installed metapackage name), or `linux-asahi` (special
  version-string munging at mklive.sh:661-663 to insert `-asahi_`). Feeds
  `IGNORE_PKGS+=(linux)` so the metapackage doesn't fight the explicit choice.
- `-x <script>` — postsetup script, run as `"$POSTSETUP_SCRIPT" "$ROOTFS"`
  right before initramfs generation (mklive.sh:703). Must be executable; runs
  with the rootfs path as `$1`, not chrooted — script decides whether to
  chroot itself.
- `-K` — keep `$BUILDDIR` instead of deleting it in `error_out`/on success (it
  isn't deleted on success either way — only `error_out` on trap deletes it,
  and only when `-K` was *not* given).
- `-k`/`-l` — keymap / locale (defaults `us` / `en_US.UTF-8`), substituted into
  boot configs and enabled in `/etc/default/libc-locales`.

os-release / issue handling: mklive.sh itself does **not** template
`/etc/os-release`. It only copies `data/motd` and `data/issue` into
`$ROOTFS/etc` if they're non-empty (mklive.sh:678-679) — CatOS branding of
`/etc/os-release` would need to happen via `-I <includedir>` (an overlay
directory containing `etc/os-release`) or a `-x` postsetup script, not by
editing mklive.sh.

SPLASH_IMAGE: defaults to `data/splash.png` (mklive.sh:613), copied into both
the isolinux dir and the grub dir, and referenced via `@@SPLASHIMAGE@@`
substitution in both `isolinux/isolinux.cfg.in` and `grub/grub_void.cfg.pre`.
There is no CLI flag to override it in mklive.sh (contrast with `mknet.sh`,
which has `-S <image>`) — override by setting the `SPLASH_IMAGE` env var
before invoking, or editing `data/splash.png` in place.

Pipeline position: standalone entry point. Not invoked by any other script in
this repo — `mkiso.sh` calls it once per desktop variant
(`./mklive.sh -a ... -o ... -p "$PKGS" -S "$SERVICES" -I "$INCLUDEDIR" ...`).
The Makefile's `void-live-%.iso` rule invokes `mkiso.sh`, never `mklive.sh`
directly.

Gotchas for future edits:
- `STEP_COUNT` (used only for the `[n/N]` progress prefix from `print_step`)
  is computed by counting conditional blocks (mklive.sh:604-609) — if you add
  a new conditional step, increment `STEP_COUNT` accordingly or the progress
  counter will overrun/undershoot.
- The EFI GRUB image build (`generate_grub_efi_boot`) builds **both** i386
  and x86_64 GRUB standalone images unconditionally for any x86 target — the
  code has a standing `# XXX: why are both built on both arches?` comment
  (mklive.sh:418) flagging this as unexplained/possibly redundant.
- `cleanup_rootfs()` removes packages in `INITRAMFS_PKGS` that aren't also in
  `PACKAGE_LIST` — if you add a package to `INITRAMFS_PKGS` that a desktop
  variant also wants installed persistently, add it to `PACKAGE_LIST` too or
  it gets stripped (or orphan-marked) after squashing.
- `generate_squashfs` sizes the ext3 loopback image as `ROOTFS_SIZE * 2`
  (mklive.sh:441) — if this stops being enough headroom for larger variants,
  ISO generation fails at the `mkfs.ext3`/copy step, not obviously at squashfs
  time.
- The two locally-redefined `mount_pseudofs`/`umount_pseudofs` in this script
  shadow lib.sh's; they don't handle `tmp` and use `--rbind` not `-r --rbind`.
  Keep local and lib.sh copies of these functions in sync if you touch
  bind-mount behavior, since three scripts (`mklive.sh`, `mkiso.sh`, and
  everything using `lib.sh`'s version directly) now have divergent copies.

---

## mkiso.sh

Purpose: wrapper around `mklive.sh` that builds "official-style" desktop
live ISOs (adds `void-installer`, desktop environment packages, audio,
accessibility, etc.) for one or more variants in a single invocation.

Key CLI flags (`getopts "a:b:d:t:hr:V"`):
- `-a <arch>` — architecture/platform (`x86_64`, `i686`, `aarch64`, `asahi`,
  any with `-musl` suffix).
- `-b <variant>` — repeatable; one of `base enlightenment xfce mate cinnamon
  gnome kde lxde lxqt xfce-wayland` (default `base`). Space-separated string
  is iterated in the final `for image in $IMAGES` loop if `-t` wasn't used.
- `-d <date>` — override the datestamp embedded in the output filename.
- `-t <arch-date-variant>` — a single combined triplet parsed with a `sed`
  regex (`^(.+)-([0-9rc]+)-(.+)$`) into arch/date/variant; equivalent to
  `-a`/`-d`/`-b` for exactly one variant. This is what the Makefile's
  `void-live-%.iso` rule uses (`mkiso.sh -t $*`).
- `-r <repo>` — passed straight through to `mklive.sh -r`.
- Anything after `--` is passed through verbatim to `mklive.sh` (e.g.
  `mkiso.sh -b gnome -- -I ./branding -o catos.iso`, per `setup.sh`'s
  documented build command).

Per-variant logic (`build_variant()`, mkiso.sh:90):
- Sets `GRUB_PKGS`/`GFX_PKGS`/`TARGET_ARCH` per arch family (x86_64/i686,
  aarch64, asahi). Only x86/i686 get `WANT_INSTALLER=yes` — arm images ship a
  stub `/usr/bin/void-installer` that just prints "not supported on this live
  image" (mkiso.sh:200-203), since arm doesn't install a kernel via
  void-installer by default.
- `asahi` forces `xfce` → `xfce-wayland` since plain xfce isn't supported
  there (mkiso.sh:119-122).
- Builds `$PKGS`/`$SERVICES` per variant (case block, mkiso.sh:135-185) —
  each desktop pulls in its own DM (lightdm/gdm/sddm), display packages, and
  `NetworkManager`/`dbus`/`polkitd` services as needed. `base` gets
  `dhcpcd wpa_supplicant acpid` instead of NetworkManager.
- `setup_pipewire()` — adds pipewire/alsa-pipewire (+ asahi-audio and
  `speakersafetyd` on asahi) and symlinks autostart/config files into
  `$INCLUDEDIR`, for every variant except `base`.
- `include_installer()` — templates `@@MKLIVE_VERSION@@` in `installer.sh`
  via `sed` (using `PROGNAME='' version` from lib.sh) and installs the result
  as `$INCLUDEDIR/usr/bin/void-installer` mode 755.
- LightDM session: if a variant sets `$LIGHTDM_SESSION`, writes
  `/etc/lightdm/.session` and a minimal `lightdm-gtk-greeter.conf` (adds the
  keyboard-layout indicator to the greeter) into the include dir.
- Finally calls:
  `./mklive.sh -a "$TARGET_ARCH" -o "$IMG" -p "$PKGS" -S "$SERVICES" \
   -I "$INCLUDEDIR" ${KERNEL_PKG:+-v $KERNEL_PKG} ${REPO} "$@"`
  — `"$@"` here is whatever followed `--` on the mkiso.sh command line, so
  user-supplied mklive.sh flags (like `-T`, extra `-I`, `-o`) land *after*
  mkiso's own flags and can override earlier ones since getopts takes the
  last occurrence for single-value options — but **not** for `-p`/`-S`/`-I`
  which accumulate, so a second `-I` from the user *adds* another include dir
  rather than replacing mkiso's.

`$INCLUDEDIR` is a fresh `mktemp -d` per `mkiso.sh` invocation (not per
variant) — it accumulates files across multiple `build_variant` calls in the
same run (e.g. if `-b` was given multiple variants) and is only removed by
`cleanup()` on `INT`/`TERM` trap or at the very end of the script; if you add
per-variant include-dir content, clear/recreate `$INCLUDEDIR` between variants
or content leaks between variant builds in a single multi-variant invocation.

Pipeline position: calls `mklive.sh` once per variant. Called by the
Makefile's `void-live-%.iso` rule (with `-P "$(LIVE_PLATFORMS)"` appended for
aarch64 targets), and directly by hand per `setup.sh`'s documented usage
(`sudo ./mkiso.sh -b gnome -- -I ./branding -o catos.iso`).

---

## mkrootfs.sh

Purpose: builds a plain Void Linux rootfs tarball for a given architecture —
no kernel, no bootloader, just packages + `base-container-full` (or whatever
`-b` specifies).

Key CLI flags: `<arch>` positional (required; i686, x86_64, armv6l/7l,
aarch64, mipsel, ppc/ppc64/ppc64le, riscv64, each with optional `-musl`
suffix). `-b <system-pkg>` (default `base-container-full`), `-c`/`-C`
cachedir/xbps conf file, `-r <repo>`, `-o <file>` output name, `-x <num>`
compressor threads.

Flow: creates a `mktemp -d` ROOTFS, seeds `var/db/xbps/keys` from `keys/*.plist`
(not the host's keys — explicit chain-of-trust reasoning in the comments,
mkrootfs.sh:130-135), runs `xbps-install -S` to sync repodata, `chmod 755`
the rootfs root, `register_binfmt`+`mount_pseudofs`, installs `$SYSPKG`,
enables `en_US.UTF-8` in `libc-locales`, runs a two-phase `xbps-reconfigure`
(host-arch pass for `base-files` first, then a full chrooted
`xbps-reconfigure -a`), sets root password to the literal string
`voidlinux` via `chpasswd` (mkrootfs.sh:206), removes the xbps passwd lockfile,
cleans `/var/cache`, then tars with `xz -9`.

Output: `void-<arch>-ROOTFS-<date>.tar.xz` by default.

Pipeline position: base input to `mkplatformfs.sh` and `mknet.sh`. Also used
directly by the Makefile's `wsl-all` target (`mkrootfs.sh ... -b wsl-base`) —
WSL images are just a mkrootfs tarball with a WSL-flavored base package, no
platformfs/image step involved.

Gotcha: default root password `voidlinux` is hardcoded, not a flag — any
CatOS rebrand that wants a different default credential has to patch this
script (mkrootfs.sh:202-206) or run a post-processing step on the tarball.

---

## mkplatformfs.sh

Purpose: takes a `mkrootfs.sh`-produced ROOTFS tarball and layers a kernel +
platform-specific packages (device trees, u-boot, cloud-init-like guest
tools) on top, producing a bootable-once-imaged PLATFORMFS tarball.

Key CLI flags: `<platform> <rootfs-tarball>` positional (required). Supported
platforms: `i686, x86_64, GCP, rpi-armv6l, rpi-armv7l, rpi-aarch64,
pinebookpro, pinephone, rock64, rockpro64, asahi` (each optionally `-musl`).
`-b <system-pkg>` (default `base-system`), `-p "<pkg> ..."` extra packages,
`-k <cmd>` post-build hook run as `<cmd> <ROOTFSPATH>`, `-n` skip compression
and just print the expanded rootfs path, `-o <file>`, `-c`/`-C`/`-r`/`-x`
same meaning as elsewhere.

Platform→package mapping (mkplatformfs.sh:122-133): `rpi*` adds `rpi-base`;
cloud/SBC platforms (`GCP`, `pinebookpro`, `pinephone`, `rock64`,
`rockpro64`) add `<platform-without-arch-suffix>-base`; `asahi` adds
`asahi-base asahi-scripts grub-arm64-efi dracut` explicitly (no generic
`-base` naming convention there). Target arch is derived via
`set_target_arch_from_platform` (lib.sh) — **this is why adding a new
platform requires updating lib.sh's platform map**, not just this script's
case statement.

initrd generation: only runs if `/boot/uInitrd` or `/boot/initrd` is missing
**and** target arch matches `*arm*` **and** `dracut`+`mkimage` binaries exist
in the rootfs (mkplatformfs.sh:181-185) — the boolean logic here is
non-obvious: `! -f uInitrd || (! -f initrd && arm && dracut && mkimage)`. Read
it carefully before touching; it's easy to misread as simple AND-of-all.
Non-arm/x86 platforms are expected to get their initrd from a different
mechanism (x86 dracut runs natively later, per the comment at
mkplatformfs.sh:172-180).

Pipeline position: input is a `mkrootfs.sh` tarball, output feeds
`mkimage.sh`. Makefile's `.SECONDEXPANSION` rule
(`void-%-PLATFORMFS-$(DATECODE).tar.xz`) computes the required ROOTFS
dependency name by shelling out to `./lib.sh platform2arch %`.

---

## mkimage.sh

Purpose: turns a `mkplatformfs.sh` tarball into a flashable/bootable disk
image (`dd`-able `.img`, later `xz`-compressed, or `.tar.gz` for cloud
platforms) — partitions a raw image, formats filesystems, unpacks the
PLATFORMFS tarball onto it, and runs platform-specific bootloader
installation. This is the step that differs most from the others: it doesn't
call `xbps-install` to add packages (the PLATFORMFS already has everything);
it operates on block devices/loop devices and partition tables.

Key CLI flags: `<platformfs-tarball>` positional (platform name is parsed out
of the filename, e.g. `void-GCP-PLATFORMFS-20260101.tar.xz` → `GCP`). `-b`/`-B`
boot fs type/size (default vfat/256MiB, bumped to 512MiB automatically for
rk33xx boards — pinebookpro/rock64/rockpro64), `-r` root fs type (default
ext4), `-s` total image size (default 900MiB), `-o` output name, `-x`
compressor threads.

Partition layout: rk33xx platforms get GPT with `first-lba: 32768` (reserved
space for the SoC's bootloader blob written directly to raw sectors); every
other platform gets MBR (`label: dos`). Root fs gets `-O ^has_journal` for
ext3/ext4 (flash-friendly, no journal).

Per-platform final configuration (`case "$PLATFORM"` at mkimage.sh:261): each
branch is genuinely different hardware-bootstrap logic —
- `rpi*`: rewrites `root=` in `/boot/cmdline.txt` to the partition's
  `PARTUUID`.
- `rock64*`/`rockpro64*`: `rk33xx_flash_uboot()` (lib.sh) `dd`s
  `idbloader.img`/`u-boot.itb` to fixed sector offsets on the loop device,
  writes `/etc/default/extlinux`, runs the kernel's own
  `/etc/kernel.d/post-install/60-extlinux` hook inside a chroot.
- `pinebookpro*`: same u-boot flash, then `xbps-reconfigure -f
  pinebookpro-kernel`.
- `pinephone*`: patches `pinephone-uboot-config`, `dd`s
  `u-boot-sunxi-with-spl.bin` to sector offset 8.
- `GCP*`: installs GRUB proper (`grub-install`), enables serial console,
  symlinks in GCP guest-agent runit services, disables getty on serial-only
  console, disables root SSH login and locks the root account (`passwd -l`),
  strips SSH host keys (regenerated on first boot), forces hostname to
  `void-GCE`.
- `asahi*`: `grub-install --target=arm64-efi --removable`, reconfigures
  `linux-asahi`.

Output naming: normal platforms get `.img` → `xz`-compressed to `.img.xz`.
`GCP*` is special-cased to rename to `disk.raw` and `tar`-gzip it to
`.tar.gz` instead (mkimage.sh:375-386) — this is mandated by Google Cloud's
image import process, not a style choice; don't "fix" it to be consistent
with the other platforms.

Pipeline position: terminal step for platform images. Input:
`mkplatformfs.sh` output only. Makefile builds both `.img.xz` (SBC) and
`.tar.gz` (cloud) targets from this same script/rule via two separate pattern
rules that both depend on the PLATFORMFS tarball.

---

## mknet.sh

Purpose: builds a PXE/network-boot tarball directly from a `mkrootfs.sh`
ROOTFS tarball (skips the PLATFORMFS/image steps entirely — it installs a
kernel and dracut netboot modules itself). Produces a tarball of loose files
(kernel, initrd, bootloader binaries, config) meant to be extracted onto a
TFTP root, not a filesystem image.

Key CLI flags: `<rootfs-tarball>` positional; target arch is parsed out of
the filename (`void-<arch>-ROOTFS-...` → `<arch>`), same pattern as
mkimage.sh. `-r`/`-c` repo/cachedir, `-i` initramfs compressor, `-o` output,
`-K linux<version>` kernel package override, `-k`/`-l` keymap/locale, `-C`
extra kernel cmdline args, `-T <title>` boot menu title, `-S <image>` custom
splash image (unlike mklive.sh, this **does** expose a flag for it).

Dracut modules installed into the rootfs before building the initrd
(mknet.sh:134-152):
- `05netmenu` (from `dracut/netmenu/`) — the PXE network boot menu, plus a
  copy of `installer.sh` itself dropped into that module directory so the
  netmenu can launch the same interactive installer used on live media.
- `01autoinstaller` (from `dracut/autoinstaller/`) — unattended install path,
  force-added ("will fail the build if it can't be installed" per the
  comment at mknet.sh:150).

Bootloader branch (mknet.sh:161-172): x86/x86_64 (`*86*` glob match) uses
`syslinux`/pxelinux — copies `pxelinux.0`, `.c32` modules, and
`pxelinux.cfg/pxelinux.cfg.in` (templated the same `@@TOKEN@@` way as
`isolinux/isolinux.cfg.in`). Everything else assumes u-boot: builds a
`uImage`/`uInitrd` pair via `mkimage -A arm ...` (the u-boot `mkimage` tool —
unrelated to this repo's own `mkimage.sh` despite the name collision).

Pipeline position: input is a `mkrootfs.sh` ROOTFS tarball only (not
PLATFORMFS — mknet.sh installs its own kernel/dracut modules straight into a
copy of the plain rootfs). Makefile's `pxe-all` target wires this up. Related
static config lives in `pxelinux.cfg/` (templates copied in) and
`dracut/{netmenu,autoinstaller}/` (modules copied in); `dracut/vmklive/` is
used by `mklive.sh`/`mkiso.sh` instead (live-media overlay module), not by
this script.

---

## installer.sh

Purpose: `void-installer` — a `dialog(1)`-driven interactive text UI
installer (1600+ lines) that partitions disks, installs Void from an XBPS
repo/local rootfs, sets up bootloader (grub-install, both BIOS and detected
UEFI via `/sys/firmware/efi/systab`), users, network, and locale. This is an
end-user tool that runs *on a booted live/netboot image*, not a build-time
script — it never runs during `mkiso.sh`/`mklive.sh` execution itself.

Not invoked directly by any other script's control flow; instead it's
**copied and templated into images**:
- `mkiso.sh`'s `include_installer()` — `sed`s `@@MKLIVE_VERSION@@` (two
  occurrences, installer.sh:100 and :108, both in `--backtitle` dialog
  headers) to the resolved `lib.sh` version string, then installs the result
  as `/usr/bin/void-installer` in the image (x86/x86_64 live variants only;
  arm gets the "not supported" stub instead, see mkiso.sh notes above).
- `mknet.sh` — copies `installer.sh` *unmodified* (no `@@MKLIVE_VERSION@@`
  substitution) into the `05netmenu` dracut module so PXE boots can launch it
  from the initrd.

Gotcha: because `mknet.sh` skips the version templating that `mkiso.sh` does,
netboot-launched installer sessions show the literal string
`@@MKLIVE_VERSION@@` in their dialog backtitle unless that's fixed — worth
checking before assuming version strings are consistent across image types.

---

## setup.sh

Purpose: one-time **host** bootstrap script (not part of the image-build
pipeline) — prepares a non-Void build machine (e.g. Ubuntu) to be able to run
`mkiso.sh`/`mklive.sh`. Marked executable as of commit `1cad250`.

What it does: if `xbps-install` isn't already on PATH, downloads
`xbps-static-latest.x86_64-musl.tar.xz` from the Void repo, extracts it, and
moves the binaries to `/usr/local/bin` (explicitly not `~/.local`, so they're
still on `root`'s `PATH` under `sudo`, which the build scripts require).
Exports `XBPS_ARCH=x86_64` (needed because static xbps on a glibc host can't
self-detect arch correctly). Installs `squashfs-tools xorriso git make` via
`apt` if present, otherwise prints a manual-install reminder for non-Debian
hosts. Runs a bare `make`, then prints the documented CatOS build command:
`sudo ./mkiso.sh -b gnome -- -I ./branding -o catos.iso`.

Gotcha: the comment above the bare `make` call says it "builds mklive's own
small helper tools" (setup.sh:23), but the top-level `Makefile`'s `all:`
target (Makefile:40) has no recipe and no prerequisites — running `make` here
is currently a no-op. Either the comment is stale or a helper-tool build step
was removed/never added; don't assume `make` alone does anything besides
validate the Makefile parses.

---

## release.sh

Purpose: does not build images locally. It's a thin `gh` (GitHub CLI) wrapper
that drives the `gen-images.yml` GitHub Actions workflow (which runs the
`Makefile` targets in CI) and handles post-build signing.

Subcommands (dispatched by prefix match on `$1`, so `st`/`start`, `d`/`dl`/
`download`, `si`/`sign` all work):
- `start [-l LIVE_ARCHS] [-f LIVE_VARIANTS] [-a ROOTFS_ARCHS] [-p PLATFORMS] \
   [-i SBC_IMGS] [-d DATE] [-r REPOSITORY] -- [gh args...]` — maps each flag
  to a `-f <workflow-input>=<value>` for `gh workflow run gen-images.yml`.
  Flag-to-input mapping is non-obvious: `-a` → `rootfs=`, `-f` → `live_flavors=`,
  `-p` → `platformfs=` (not "platform packages"), `-r` → `mirror=`.
- `dl [run id] -- [gh args...]` — downloads artifacts matching `void-live*`
  from a given run, or the latest successful `gen-images.yml` run if no run
  id given (`gh run list -s success ... | sort -r | head -1` — a comment
  flags this as a workaround for `gh` CLI issue #4001, since gh can't
  directly ask for "latest successful run").
- `sign DATE SHASUMFILE` — generates a one-time minisign keypair named after
  the release date (`release/void-release-<date>.{key,pub,sec}`), signs the
  given checksum file, producing a `.sig`. The `.key` file (a `pwgen`-random
  passphrase) is the "password" fed to `minisign -s ... < key` on stdin, not
  a stored keypair meant for reuse across releases — a new key is minted per
  release.

Pipeline position: `release.sh start` is the human-facing entry point that
kicks off the entire CI build matrix (which internally runs `make
live-iso-all`, `make rootfs-all`, `make platformfs-all`, `make
images-all-sbc`, `make wsl-all`, `make checksum`, per `.github/workflows/gen-images.yml`).
It does not read or write the top-level `version` file — nothing in this
repo currently automates bumping `version`; it's bumped manually (see commit
history: `git log -- version` shows repeated plain `version: bump` commits).

---

## Makefile

Purpose: batch-orchestrates every script above across architecture/variant
matrices, primarily for CI (`.github/workflows/gen-images.yml` calls `make`
targets with matrix-driven `ARCHS`/`LIVE_ARCHS`/`PLATFORMS`/etc. overrides).

Key variables: `T_LIVE_ARCHS`, `T_PLATFORMS`, `T_ARCHS`, `T_SBC_IMGS`,
`T_CLOUD_IMGS`, `T_PXE_ARCHS`, `T_WSL_ARCHS` define brace-expansion templates
(e.g. `i686 x86_64{,-musl} aarch64{,-musl} asahi{,-musl}`) that get expanded
via `$(shell echo ...)` into the actual `ARCHS`/`LIVE_ARCHS`/etc. lists used
to generate target names. `LIVE_FLAVORS` lists the desktop variants passed to
`mkiso.sh -b`. `DATECODE` defaults to today's UTC date but every rule accepts
override.

Key targets:
- `README.md` — regenerates the top-level README from `README.md.in` plus
  the live `-h` usage output of `mkiso mklive mkrootfs mkplatformfs mkimage
  mknet` (each script's usage text is embedded verbatim). **If you change any
  script's `usage()` text or add/remove a flag, run `make README.md` or the
  README drifts out of sync** — nothing else regenerates it automatically.
- `live-iso-all` / `void-live-%.iso` — calls `mkiso.sh -r $(REPOSITORY) -t $*`
  per arch/variant/date triplet; aarch64 targets additionally get
  `-- -P "$(LIVE_PLATFORMS)"` appended (`LIVE_PLATFORMS:=pinebookpro x13s`).
- `rootfs-all` / `void-%-ROOTFS-...` — calls `mkrootfs.sh`.
- `platformfs-all` / `void-%-PLATFORMFS-...` — uses `.SECONDEXPANSION` to
  compute its own ROOTFS prerequisite via `./lib.sh platform2arch %` (see
  lib.sh notes) before calling `mkplatformfs.sh`.
- `images-all` (= `images-all-sbc` + `images-all-cloud`) / `mkimage.sh` rules
  — two separate pattern rules for the same script: `.img.xz` targets (SBC,
  xz-compressed) and `.tar.gz` targets (cloud, comment at Makefile: "Some of
  the images MUST be compressed with gzip rather than xz, this rule services
  those images" — actually just re-runs `mkimage.sh` without `-o` since the
  GCP branch inside mkimage.sh handles its own `.tar.gz` renaming).
- `pxe-all` / `void-%-NETBOOT-...` — calls `mknet.sh` on a ROOTFS tarball
  (not PLATFORMFS).
- `wsl-all` / `void-%-....wsl` — calls `mkrootfs.sh -b wsl-base` directly (no
  platformfs/image step for WSL).
- `dist` — moves all `void*<datecode>*` artifacts into `distdir-<datecode>/`.
- `checksum` — `sha256sum *` inside the distdir (note: invoked as `sha256`,
  not `sha256sum`, at Makefile — verify this binary name exists on the CI
  runner if checksum generation is ever debugged).

`mkiso.sh: mklive.sh` is a dependency declaration (mkiso.sh's file mtime
depends on mklive.sh's) purely for the `README.md` target's prerequisite
list — it does not mean `make` rebuilds `mkiso.sh` from `mklive.sh` in any
compiled sense; both are static shell scripts.

`SUDO := sudo` is prefixed onto every rule that actually builds an image —
if running as root already (e.g. inside a CI container), this is harmless
but redundant.

---

## version

Purpose: single-line file (currently `0.26`) holding the project's version
number. No suffix/newline conventions beyond a bare string.

Read by: `lib.sh`'s `version()` function only (`cat ./version`), always
relative to the current working directory — **scripts must be run from the
repo root** or this (and `keys/*.plist`, `data/*`, `grub/*`, `isolinux/*`
lookups elsewhere) resolve incorrectly. Combined with
`git rev-parse --short HEAD` (or `$MKLIVE_REV` if set, letting CI pin a
specific rev string instead of relying on the checkout's HEAD) to produce the
string every script prints for its `-V` flag, and what `mkiso.sh` bakes into
`installer.sh`'s `@@MKLIVE_VERSION@@` placeholder.

Never written by any script in this repo — bumping it is a manual edit
(confirmed via `git log -- version`, which shows a series of plain
`version: bump` commits with no accompanying automation). If CatOS wants
version bumps automated (e.g. tied to `release.sh start`), that would be new
work, not something to look for in existing scripts.
