# Branding, boot-menu, platform, and alt-build layer

This covers everything that turns a stock Void Linux build into "CatOS",
plus the non-ISO output paths (Packer images, the container build
environment) that live alongside the core `mklive.sh`/`mkiso.sh` pipeline.
The core pipeline itself is documented separately (`build-pipeline.md`);
this file only notes the connection points.

## `branding/` — ROOTFS overlay

**Purpose:** directory tree that gets copied verbatim onto the built
ROOTFS, for anything expressible as "drop these files in."

**Current state:** as of this writing, `branding/` contains only
`README.md` — no actual overlay files exist yet. The mechanism is wired up
and documented but unpopulated. This is where a CatOS `/etc/os-release`,
motd, wallpapers, and skel dotfiles are meant to go once created.

**Key file:**
- `branding/README.md` — explains the mechanism.

**How it works:** `mklive.sh -I <dir>` (equivalently `mkiso.sh -- -I <dir>`)
copies the entire contents of `<dir>` onto the ROOTFS, preserving the
directory structure. The directory must mirror the target filesystem, e.g.:

```
branding/
  etc/
    os-release      # distro name/version — read by neofetch, fastfetch, etc.
    motd
    skel/...        # default dotfiles for new users
  usr/
    share/
      backgrounds/catos/...
```

**How to customize (OS name/version branding):** create
`branding/etc/os-release` with CatOS's identity (`NAME`, `PRETTY_NAME`,
`VERSION`, `ID`, etc., standard `os-release(5)` fields) and build with:

```bash
sudo ./mkiso.sh -b gnome -- -I ./branding -o catos.iso
```

Nothing else needs to change — `mklive.sh` copies the whole tree during
the build. No `os-release` currently exists in the repo, so this file must
be authored before the distro identifies itself as CatOS to userspace
tools.

**Not handled through `-I`** (per `branding/README.md`, wired via fixed
paths in the upstream scripts instead):
- Boot splash image — `data/splash.png`, referenced by `mklive.sh`'s
  `SPLASH_IMAGE` variable.
- Live-session welcome text — `data/issue`, copied to `/etc/issue`.
- Bootloader title — not a file; set via `mklive.sh -T "CatOS"` (see
  `README.md` "Customizing the image" section).

**Connection to core pipeline:** `mkiso.sh` forwards everything after `--`
to `mklive.sh`, so `-I ./branding` is passed straight through
(`mkiso.sh:209` builds the `mklive.sh` invocation including `-I
"$INCLUDEDIR"`). Inside `mklive.sh`, `-I` populates a directory that gets
`cp -R`'d onto the ROOTFS (see `mklive.sh -h`, option `-I <includedir>`).

## `data/issue` — live-session welcome text

**Purpose:** the message printed on the console/TTY at login in the live
session (copied to `/etc/issue`).

**Current content:** stock Void Linux welcome text — login credentials
(`root:voidlinux`, `anon:voidlinux`), instructions to run `void-installer`,
`xbps-install`/`xbps-query` pointers, `void-docs`, and a link to
`voidlinux.org`. None of this has been reworded for CatOS yet.

**How to customize:** edit `data/issue` in place (per `branding/README.md`,
replace rather than duplicate under `branding/`). Update the login
credential lines and the void-linux.org URL/branding text if the distro's
default users or install tooling differ.

**Connection to core pipeline:** `mklive.sh` copies this file to
`/etc/issue` on the ROOTFS by fixed path (not via `-I`).

## `data/splash.png` — boot splash image

**Purpose:** the background image shown by GRUB and isolinux/vesamenu
during the boot menu.

**Format:** binary PNG asset, no text content to document.

**How to customize:** replace `data/splash.png` in place with an image of
the same/compatible format. `mklive.sh` defaults `SPLASH_IMAGE` to
`data/splash.png` (`mklive.sh:613`: `: ${SPLASH_IMAGE:=data/splash.png}`)
but this can be overridden with a different path via the `mklive.sh`
splash-image option — check `mklive.sh -h` for the current flag if
pointing at a file outside `data/`.

**Connection to core pipeline:** `mklive.sh` copies `$SPLASH_IMAGE` into
the ISO's isolinux directory (`mklive.sh:265` and `:284`, `cp -f
${SPLASH_IMAGE} "$ISOLINUX_DIR"`) and substitutes its basename into the
`@@SPLASHIMAGE@@` token in both the GRUB and isolinux/pxelinux config
templates (`mklive.sh:267`, `:382`).

## `grub/` — GRUB boot menu templates

**Purpose:** GRUB configuration sourced when booting the ISO/USB on UEFI
or GRUB-BIOS systems.

**Key files:**
- `grub/grub.cfg` — the minimal top-level config GRUB actually loads from
  the boot media. It just loads a handful of filesystem/module drivers,
  searches for `/boot/grub/grub_void.cfg`, and sources it. Contains no
  branding tokens itself.
- `grub/grub_void.cfg.pre` — the real menu config template (prefix
  section): sets up graphics/gfxterm, loads the unicode font, sets
  `background_image` to `(${voidlive})/boot/isolinux/@@SPLASHIMAGE@@`,
  sets `default=linux`, `timeout=15`, and starts a `cpuid -l` conditional
  (long-mode check) that `mklive.sh` uses to branch menu entry generation.
- `grub/grub_void.cfg.post` — a one-line closer: `fi # for if [ cpuid -l ]
  in grub_void.cfg.pre`. `mklive.sh` builds the final
  `boot/grub/grub_void.cfg` by concatenating `.pre` + generated menu
  entries (per-arch/per-platform, plus platform submenus) + `.post`.

**Placeholder tokens found:** only `@@SPLASHIMAGE@@` appears directly in
these three files (in `.pre`). The other tokens (`@@BOOT_TITLE@@`,
`@@KERNVER@@`, `@@ARCH@@`, `@@KEYMAP@@`, `@@LOCALE@@`, `@@BOOT_CMDLINE@@`)
are not present as literal text here — GRUB menu entries are generated
programmatically by `mklive.sh` (e.g. `mklive.sh:312`, `ENTRY_TITLE="${BOOT_TITLE}
${KERNELVERSION} ${title_sfx}(${TARGET_ARCH})"`) and appended between the
`.pre` and `.post` fragments, rather than substituted into a static
template the way isolinux/pxelinux do it.

**How to customize:** the boot title comes from `mklive.sh -T "CatOS"`
(README-documented flag), not from editing these files. To change the
splash background positioning/behavior or add new GRUB modules, edit
`grub_void.cfg.pre` directly.

**Connection to core pipeline:** `mklive.sh:267` substitutes
`@@SPLASHIMAGE@@` with `$(basename "${SPLASH_IMAGE}")` when writing out
the isolinux config, and `mklive.sh:382` does the same substitution
directly against the assembled `$GRUB_DIR/grub_void.cfg`.

## `isolinux/isolinux.cfg.in` — legacy BIOS boot menu template

**Purpose:** boot menu shown on legacy BIOS boot (non-UEFI), rendered
through `vesamenu.c32`.

**Placeholder tokens:** `@@SPLASHIMAGE@@` (background), `@@BOOT_TITLE@@`,
`@@KERNVER@@`, `@@ARCH@@` (each menu label, e.g. `MENU LABEL @@BOOT_TITLE@@
@@KERNVER@@ @@ARCH@@`), `@@KEYMAP@@`, `@@LOCALE@@`, `@@BOOT_CMDLINE@@`
(kernel APPEND line).

**Menu entries defined:** `linux` (normal boot), `linuxram` (copy to RAM),
`linuxnogfx` (`nomodeset`), `linuxa11y` / `linuxa11yram` /
`linuxa11ynogfx` (speech-accessible variants with autologin), plus
`c` (chainload first HD), `memtest` (Memtest86+), `reboot`, `poweroff`.
Colors are hardcoded: title/selection background `#FF5255FF` (a red),
selection text white, transparent border.

**How to customize:** the `MENU COLOR` lines are the only actual color
branding surface — edit the hex values directly in `isolinux.cfg.in` to
reskin the boot menu color scheme. Title text comes from `-T` at build
time, not from this file. `TIMEOUT 150` (15s) controls the auto-boot
delay.

**Connection to core pipeline:** `mklive.sh:267-273` runs a `sed`
substitution over this file (well, over the generated `isolinux.cfg`) for
all six tokens listed above, using `$SPLASH_IMAGE`, `$KERNELVERSION`,
`$KEYMAP`, `$TARGET_ARCH`, `$LOCALE`, `$BOOT_TITLE`, `$BOOT_CMDLINE`.

## `pxelinux.cfg/pxelinux.cfg.in` — PXE network boot menu template

**Purpose:** boot menu served to machines PXE-booting the live image over
network, also via `vesamenu.c32`.

**Placeholder tokens:** same family as isolinux —
`@@SPLASHIMAGE@@`, `@@BOOT_TITLE@@`, `@@KERNVER@@`, `@@ARCH@@`,
`@@KEYMAP@@`, `@@LOCALE@@`, `@@BOOT_CMDLINE@@`.

**Menu entries defined:** only two real boot options plus chainload:
`menu` ("Interactive Session [@@BOOT_TITLE@@] (@@KERNVER@@ @@ARCH@@)",
`root=/dev/null`), `auto` ("AutoInstall [...]", same but with `auto` on
the kernel cmdline for unattended install), and `c` (chainload first HD).
No memtest/reboot/poweroff/accessibility entries here (smaller menu than
isolinux's). Same red (`#FF5255FF`) color scheme, `TIMEOUT 100` (10s),
`ONTIMEOUT c` (default is to boot local disk, not the network image,
unlike isolinux which defaults to `linux`).

**How to customize:** same as isolinux — edit `MENU COLOR` hex values for
a different boot-menu palette; labels are template strings filled at
build time.

**Connection to core pipeline:** substituted by the same `mklive.sh`
sed pass pattern used for isolinux (same token set, same source
variables).

## `platforms/` — ARM platform definitions

**Purpose:** per-board configuration for aarch64 targets (adds packages
and a GRUB submenu entry for a specific device).

**Key files:**
- `platforms/README.md` — documents the file format and the `mklive.sh -P
  "platform1 platform2 ..."` flag.
- `platforms/pinebookpro.sh` — `PLATFORM_NAME="Pinebook Pro"`,
  `PLATFORM_PKGS=(pinebookpro-base)`, `PLATFORM_CMDLINE="console=ttyS2,115200
  video=eDP-1:1920x1080x60"`, `PLATFORM_DTB="rockchip/rk3399-pinebook-pro.dtb"`.
- `platforms/x13s.sh` — `PLATFORM_NAME="Thinkpad X13s"`,
  `PLATFORM_PKGS=(x13s-base)`, `PLATFORM_CMDLINE="rd.driver.blacklist=qcom_q6v5_pas
  arm64.nopauth clk_ignore_unused pd_ignore_unused"`,
  `PLATFORM_DTB="qcom/sc8280xp-lenovo-thinkpad-x13s.dtb"`.

**Variables a platform file defines:**
- `PLATFORM_NAME` — optional pretty name used in the GRUB submenu title.
- `PLATFORM_PKGS` — bash array of extra packages appended to the image's
  package list.
- `PLATFORM_CMDLINE` — extra kernel cmdline args appended to every menu
  entry generated for this platform.
- `PLATFORM_DTB` — device tree path relative to
  `/boot/dtbs/dtbs-$version/`, copied into the ISO's boot dir.

**Important correction to check when reading `mkplatformfs.sh`:** these
files are **not** sourced by `mkplatformfs.sh` — that script (which builds
generic PLATFORMFS tarballs for bootstrapping ARM systems) contains no
reference to `platforms/`, `PLATFORM_*`, or `PLATFORMS` at all. The
`platforms/*.sh` files are sourced directly by **`mklive.sh`** in two
places: once early (`mklive.sh:566-573`) to fold `PLATFORM_PKGS` into the
image's package list, and once later during GRUB config generation
(`mklive.sh:331-342`) to emit a `submenu "... for <PLATFORM_NAME> >"`
block per platform and write per-platform boot entries with
`PLATFORM_CMDLINE`/`PLATFORM_DTB` applied.

**How to customize:** add a new `platforms/<name>.sh` following the format
above, then build with `mklive.sh -P "<name>"` (space-separated list for
multiple platforms in one image). This only applies to aarch64 builds.

**Connection to core pipeline:** consumed only by `mklive.sh` (via the
`-P` flag, `mklive.sh:523` `PLATFORMS+=($OPTARG)`), not by `mkiso.sh`,
`mkrootfs.sh`, or `mkplatformfs.sh`.

## `keys/*.plist` — xbps package-signing keys

**Purpose:** these are **Void Linux's own** xbps repository signing keys
(fingerprint-named `.plist` files, Apple-style plist format containing a
base64 RSA-4096 public key and `signature-by: Void Linux`), not
CatOS-specific keys. There is no CatOS signing key here.

**Key files:**
- `keys/60:ae:0c:d6:f0:95:17:80:bc:93:46:7a:89:af:a3:2d.plist`
- `keys/3d:b9:c0:50:41:a7:68:4c:2e:2c:a9:a2:5a:04:b7:3f.plist`

Both contain `public-key`, `public-key-size` (4096), and `signature-by`
(`Void Linux`) fields — standard xbps trusted-key format.

**How it's used:** copied verbatim into the built ROOTFS's
`/var/db/xbps/keys/` so xbps trusts the Void repos out of the box:
`mklive.sh:116` (`cp keys/*.plist "$1"/var/db/xbps/keys`) and
`mkrootfs.sh:137` (same). Also referenced by the dracut installer modules
(`dracut/autoinstaller/module-setup.sh`, `dracut/autoinstaller/install.sh`,
`dracut/netmenu/module-setup.sh`) which pull keys from the *running
system's* `/var/db/xbps/keys/*` into the installed target, not from this
directory directly.

**How to customize for CatOS:** if CatOS ships its own xbps repo with
independently-signed packages, add a new `.plist` here (named by the
key's fingerprint) containing the new public key, so builds trust that
repo. Nothing in the current repo does this — both keys present are
upstream Void keys.

## `packer/` — Packer-based image builds (separate from mklive.sh/mkiso.sh)

**Purpose:** builds Vagrant boxes and generic cloud (qemu/qcow2) images by
booting the **official upstream Void Linux ISO** (not a CatOS-built one)
in QEMU/VirtualBox and running an unattended `void-installer` (AutoInstall)
against it, then post-processing. This path does not consume `mklive.sh`,
`mkiso.sh`, `branding/`, or any of the other files in this doc — it is a
fully independent build pipeline that happens to live in the same repo.

**Key files:**
- `packer/plugins.pkr.hcl` — declares the `qemu`, `vagrant`, and
  `virtualbox` Packer plugins required.
- `packer/hcl2/source-qemu.pkr.hcl` — QEMU source: boots
  `https://repo-default.voidlinux.org/live/20240314/void-live-x86_64-20240314-base.iso`
  (a pinned upstream ISO, with sha256 checksum), KVM accel, 2000M qcow2
  disk.
- `packer/hcl2/source-virtualbox-ose.pkr.hcl` — same upstream ISO via
  VirtualBox, guest additions disabled, virtio NIC.
- `packer/hcl2/build-vagrant.pkr.hcl` — two builds
  (`vagrant-virtualbox-x86_64`, `vagrant-virtualbox-x86_64-musl`) that boot
  the VirtualBox source with an `autourl=` boot command pointing Void's
  installer at `http/x86_64.cfg` / `http/x86_64-musl.cfg`, run
  `scripts/vagrant.sh`, and post-process into a `.box` via the `vagrant`
  post-processor.
- `packer/hcl2/build-cloud-generic.pkr.hcl` — same pattern but against the
  QEMU source, running `scripts/cloud.sh`, output is just the qcow2 image
  directory (no post-processor/box step).
- `packer/http/x86_64.cfg` / `packer/http/x86_64-musl.cfg` — Void
  AutoInstall (`void-installer`) config files served over HTTP during the
  boot process (`autourl=http://{{.HTTPIP}}:{{.HTTPPort}}/...`). Both set
  `username=void`, `password=void`, define `VAI_partition_disk`
  (single-partition `sfdisk`), `VAI_format_disk` (`mkfs.ext4`),
  `VAI_mount_target`, `VAI_configure_fstab`, and an `end_function` that
  symlinks `dhcpcd`/`sshd` into runit's default runsvdir and reboots. The
  `-musl` variant additionally exports `XBPS_ARCH=x86_64-musl` and points
  `xbpsrepository` at the musl repo.
- `packer/http/cloud.cfg` — byte-identical to `x86_64.cfg` (confirmed via
  diff). Not referenced by any `.pkr.hcl` file in this repo — appears to
  be an unused/leftover config; the cloud builds actually use
  `x86_64.cfg`/`x86_64-musl.cfg`.
- `packer/scripts/vagrant.sh` — post-install provisioner: creates a
  `vagrant` user, passwordless sudo, drops the insecure Vagrant SSH
  public key into `~vagrant/.ssh/authorized_keys`, installs `nfs-utils`,
  locks the `vagrant`/`void`/`root` passwords, clears the xbps cache, and
  shuts the VM down (so Packer can snapshot the disk).
- `packer/scripts/cloud.sh` — post-install provisioner for cloud images:
  passwordless sudo for `void`, installs `cloud-guest-utils`, enables the
  `shinit` (cloud-init-like first-boot) runit service, enables
  `growpart` in `/etc/default/growpart`, locks `void`/`root` passwords,
  strips SSH host keys (regenerated on first boot) and xbps cache, shuts
  down.
- `packer/.gitignore` — ignores Packer's own `output_*`, `packer_cache`,
  `crash.log`, `*.box`, `templates/`, `cloud-generic`.

**How to customize:** to make these produce CatOS-branded boxes/images,
the `iso_url`/`iso_checksum` in the two `source-*.pkr.hcl` files would
need to point at a CatOS-built ISO instead of the upstream Void one (or a
CatOS-specific rootfs/AutoInstall config), since currently every Packer
build boots stock upstream Void and never touches `branding/`,
`data/issue`, or `data/splash.png`.

**Connection to core pipeline:** none at present — no shared variables,
no shared scripts, no dependency in either direction. This is a distinct,
parallel build path bolted onto the same repo, working from an upstream
Void ISO URL rather than anything `mklive.sh`/`mkiso.sh` produce.

## `container/` — mklive build-environment container

**Purpose:** a container image that packages up the tools needed to *run*
`mklive.sh`/`mkiso.sh`/etc. (cross-arch build environment), not a
container image *of* CatOS/Void itself. Published to
`ghcr.io/<owner>/void-mklive` per `.github/workflows/container.yaml`.

**Key files:**
- `container/Containerfile` — based on
  `ghcr.io/void-linux/void-glibc-full:latest`; syncs xbps and the repo
  package set from `$MIRROR/current` (default
  `https://repo-default.voidlinux.org/`), then installs `bash make git
  kmod xz lzo qemu-user-arm qemu-user-aarch64 binfmt-support outils
  dosfstools e2fsprogs` — i.e. exactly the toolchain needed to run the
  mklive scripts and cross-build/emulate arm/aarch64 targets via
  QEMU user-mode + binfmt.
- `container/docker-bake.hcl` — Buildx bake file. `MIRROR` variable
  defaults to `https://repo-ci.voidlinux.org/` (a CI-specific mirror,
  different default than the Containerfile's own
  `repo-default.voidlinux.org`). Defines target `void-mklive` (inherits
  `_common`), building for `linux/amd64` and `linux/arm64`, with local
  buildx cache dirs.
- `.github/workflows/container.yaml` — builds/pushes this image on any
  push/PR touching `container/**`, tagging with a date-based release
  scheme (`YYYYMMDDRN`) plus `latest` on the default branch.

**How to customize:** to rebrand this as a CatOS-flavored build
environment (e.g. if CatOS ends up with its own package mirror), change
the `MIRROR` default in `docker-bake.hcl` and/or the `ARG MIRROR` default
in `Containerfile`, and update the ghcr.io image name in the workflow.

**Connection to core pipeline:** this is the *environment the pipeline
runs in*, not an output of it — a user could `docker run` this image and
then invoke `mklive.sh`/`mkiso.sh` inside it instead of installing the
build dependencies on bare metal. It does not invoke or reference
`mklive.sh` itself anywhere in its build steps.

## Summary: renaming/rebranding the OS (cross-cutting answer)

For a user asking "how do I rename this to CatOS" / "how do I change the
boot title and splash":

1. **OS name/version/identity** (`neofetch`, `fastfetch`, `/etc/os-release`
   consumers): create `branding/etc/os-release` (does not exist yet — repo
   ships an empty `branding/` today) and build with
   `mklive.sh -I ./branding` (or `mkiso.sh -- -I ./branding`).
2. **Boot menu title** (shown in GRUB/isolinux/pxelinux menu labels via
   `@@BOOT_TITLE@@`): pass `mklive.sh -T "CatOS"` (defaults to `"Void
   Linux"` per `mklive.sh:550`). Not a file — a build-time flag.
3. **Boot splash image** (GRUB `background_image` + isolinux/pxelinux
   `MENU BACKGROUND`, both via `@@SPLASHIMAGE@@`): replace `data/splash.png`
   in place, or point `SPLASH_IMAGE` at a different file (default
   `mklive.sh:613`).
4. **Boot menu color scheme**: edit `MENU COLOR` hex values directly in
   `isolinux/isolinux.cfg.in` and `pxelinux.cfg/pxelinux.cfg.in` (currently
   both hardcoded to `#FF5255FF` red).
5. **Live-session welcome text**: edit `data/issue` in place.
6. None of the Packer (`packer/`) or container (`container/`) build paths
   pick up any of this branding — they build from/for upstream Void
   directly and are unaffected by `branding/`, `-T`, or `data/*`.
