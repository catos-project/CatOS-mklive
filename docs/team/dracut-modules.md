# Dracut modules (runtime live-boot configuration)

This documents the three dracut module trees in `dracut/`: `vmklive` (core live
environment setup), `autoinstaller` (unattended install, VAI), and `netmenu`
(PXE boot menu, not used by the ISO build). These modules run inside the
initramfs while the live image boots — they configure the just-built root
filesystem (`$NEWROOT`) before or during pivot to it, not at package-build
time. Package-build-time logic (which packages/DEs get installed) lives in
`mklive.sh`, not here.

Dracut module conventions used throughout: a `module-setup.sh` per module
directory defines `check()` (inclusion opt-out, all three modules force
`return 255` — never auto-include, must be force-added), `depends()` (other
dracut modules this one requires), and `install()` (copies binaries/files into
the initramfs and registers hook scripts with `inst_hook <hookpoint>
<priority> <script>`). Hook points used here, in the order dracut runs them:
`pre-mount` → `cmdline` → `pre-udev` → (udev/device settle) → `pre-pivot`.
`pre-pivot` runs after the real root is mounted at `$NEWROOT` but before
switch-root, so scripts there can edit files under `$NEWROOT` directly.

How these modules get into a build (they are not auto-included by dracut's
dependency resolution — every build must force-add them):

```sh
# mklive.sh (ISO build) — generate_initramfs()
copy_dracut_files "$ROOTFS"          # dracut/vmklive/*      -> .../modules.d/01vmklive
copy_autoinstaller_files "$ROOTFS"   # dracut/autoinstaller/* -> .../modules.d/01autoinstaller
dracut ... --force-add "vmklive autoinstaller" ...
```

`netmenu` is **not** copied or force-added by `mklive.sh` — it is only used by
`mknet.sh` (PXE tarball build), which force-adds `autoinstaller netmenu`
instead. If you're only building the ISO, `dracut/netmenu/` is dead code.

---

## dracut/vmklive/ — core live-environment module

### module-setup.sh

Purpose: assembles the live-boot module; installs helper binaries and wires up
all the other `vmklive` scripts as `pre-pivot` hooks, in a fixed order.

```sh
depends() { echo dmsquash-live; }   # requires dracut's squashfs live-root module

install() {
    inst /usr/bin/chroot /usr/bin/chmod /usr/bin/sed
    if [ -e /usr/bin/memdiskfind ]; then      # MTD support, conditional on host tool
        ...
        inst_hook pre-udev 01 "$moddir/mtd.sh"
    fi
    [ -f "$moddir/adduser.sh" ]                   && inst_hook pre-pivot 01 "$moddir/adduser.sh"
    [ -f "$moddir/display-manager-autologin.sh" ] && inst_hook pre-pivot 02 "$moddir/display-manager-autologin.sh"
    [ -f "$moddir/getty-serial.sh" ]              && inst_hook pre-pivot 02 "$moddir/getty-serial.sh"
    [ -f "$moddir/locale.sh" ]                    && inst_hook pre-pivot 03 "$moddir/locale.sh"
    [ -f "$moddir/accessibility.sh" ]             && inst_hook pre-pivot 04 "$moddir/accessibility.sh"
    [ -f "$moddir/nomodeset.sh" ]                 && inst_hook pre-pivot 05 "$moddir/nomodeset.sh"
}
```

Execution order at `pre-pivot` matters: `adduser.sh` (01) must run before
`display-manager-autologin.sh` (02) because the latter only sets `$USERNAME`
in DM config files — it assumes the user already exists. `getty-serial.sh`
shares priority 02 with the autologin script (order between same-priority
hooks is filesystem/glob order, i.e. not guaranteed — they don't touch the
same files so this is safe in practice).

Gotcha: every hook is gated with `[ -f "$moddir/<script>" ]`. Deleting a
script file is enough to silently disable that stage — there's no error if
one goes missing, the feature just stops applying.

### adduser.sh — live user creation

Purpose: creates the live-session user, sets root/user passwords, grants
passwordless sudo, and (optionally) wires tty1 autologin.

Runs at `pre-pivot` priority 01, first of the vmklive hooks.

Key knobs (kernel cmdline, via `getarg`):
- `live.user` — username for the live account (default `anon`)
- `live.shell` — login shell for that user (default `/bin/bash` if present in
  `$NEWROOT`, else `/bin/sh`)
- `live.autologin` (boolean, via `getargbool 0 live.autologin`) — if true,
  patches `/etc/sv/agetty-tty1/conf` to add `-a $USERNAME` to `GETTY_ARGS`,
  making tty1's agetty autologin that user at the text console.

```sh
USERNAME=$(getarg live.user); [ -z "$USERNAME" ] && USERNAME=anon
chroot ${NEWROOT} useradd -m -c $USERNAME -G audio,video,wheel -s $USERSHELL $USERNAME
chroot ${NEWROOT} passwd -d $USERNAME >/dev/null 2>&1     # delete password (blank)
chroot ${NEWROOT} sh -c 'echo "root:voidlinux" | chpasswd -c SHA512'
chroot ${NEWROOT} sh -c "echo "$USERNAME:voidlinux" | chpasswd -c SHA512"
echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "${NEWROOT}/etc/sudoers.d/99-void-live"
```

Also writes `${NEWROOT}/etc/default/live.conf` with `USERNAME=...` — other
tooling in the live rootfs (e.g. the installer, if it needs to know/remove the
live user) reads this to find the account name. Also drops a polkit rule
granting the `wheel` group admin/YES for everything, if `/etc/polkit-1` exists.

Note the dual password setup: `passwd -d` blanks the password (so text-console
/ PAM-less login has no password prompt) but `chpasswd` also sets it to
`voidlinux` — this covers callers that require a non-empty hash (e.g. some PAM
stacks or DM greeters that reject blank passwords outright) as well as ones
that accept blank. Root gets the same `voidlinux` password. This is a live/demo
image; it is not meant to be an internet-facing default.

Gotcha: only tty1 gets autologin patched. Other ttys (tty2+) are untouched.
`live.autologin` is not passed by the default boot menu entries — see the
mklive.sh grub-entry note near the bottom of this doc.

### display-manager-autologin.sh — THIS decides the default logged-in desktop

Purpose: configures autologin for whichever graphical display manager is
present in the built rootfs, and for lxdm specifically, also decides *which
session/DE* gets launched.

Runs at `pre-pivot` priority 02. Depends on `adduser.sh` having already run
(same `$USERNAME` resolution: `live.user`, default `anon`).

This is unconditional — it does **not** check `live.autologin`. If a DM's
config file exists in `$NEWROOT`, this script patches it to autologin
`$USERNAME` regardless of the `live.autologin` cmdline flag. (`live.autologin`
in `adduser.sh` only controls the *text console* tty1 autologin; graphical
autologin is controlled entirely by this script and is always applied when the
corresponding DM is installed.)

Per-DM behavior — **this is the mechanism that determines which DE shows up
as the default graphical session on boot**:

- **GDM**: sets `AutomaticLoginEnable=true` / `AutomaticLogin=$USERNAME` in
  `/etc/gdm/custom.conf`. Does not pick a session — GNOME/GDM uses its own
  last-used-session or default-session logic once autologin happens. Guarded
  against re-adding the block if `AutomaticLoginEnable` is already present
  (so persistent live USB re-boots don't duplicate config).

- **SDDM**: writes `/etc/sddm.conf` from scratch with
  `[Autologin] User=$USERNAME` and **hardcodes** `Session=plasma.desktop`.
  ```
  [Autologin]
  User=${USERNAME}
  Session=plasma.desktop
  ```
  This is KDE Plasma specific — comment in the script literally says "for the
  kde iso". If you build an SDDM-based ISO with a different DE, this line is
  wrong and must be edited (or the file it writes will point at a
  `plasma.desktop` session that may not exist).

- **lightdm**: edits `/etc/lightdm/lightdm.conf` in place via `sed`,
  uncommenting `autologin-user=`, `autologin-user-timeout=0`,
  `autologin-session=`, and `user-session=`. The session name for the latter
  two is pulled from **`/etc/lightdm/.session`** — a file that must already
  exist in the rootfs (presumably dropped in by package postinstall/branding,
  not by this script) containing the desired session id (e.g. `xfce`,
  `cinnamon`). If `/etc/lightdm/.session` doesn't exist, `cat` fails and the
  session lines get set to an empty value.

- **lxdm**: rewrites the `autologin=` line in `/etc/lxdm/lxdm.conf` to
  `$USERNAME`, and additionally overwrites the `session=` line by probing for
  installed session binaries in a fixed priority order:
  `enlightenment_start` → `startxfce4` → `mate-session` → `cinnamon-session`
  → `i3` → `startlxde` → `startlxqt` → `startfluxbox`. First one found on disk
  wins. This is the one place in the module where "which DE is default" is
  decided by package presence rather than by a hardcoded name.

**To change the default DE/session for a given ISO**, the fix depends on which
DM the ISO ships:
- SDDM: edit the `Session=plasma.desktop` line in this script.
- lightdm: ensure `/etc/lightdm/.session` contains the desired session id
  (this file's origin is outside this module — check package postinstalls /
  branding files).
- lxdm: reorder or extend the `elif` chain of session binaries.
- GDM: not controlled here at all — GDM/GNOME picks its own default session;
  autologin only picks the *user*, not the session.

Gotcha: all four blocks are independent `if` checks (not mutually exclusive
`elif`), so if a rootfs somehow has more than one DM's config file present,
more than one block will apply and only the DM actually running determines
the visible effect. Also, none of this activates or enables a DM's runit
service — it only edits config files; whatever runit service symlinks are
already set up by package installation / `mklive.sh -S` determine which DM
(if any) actually starts. So "which DM is installed and enabled as a runit
service" and "which session that DM launches" are two separate concerns —
this script only controls the second one (session selection is DM-specific
as described above), plus the login-user for both.

### accessibility.sh

Purpose: enables console screen-reader / braille services on request.

Runs at `pre-pivot` priority 04.

Knob: `live.accessibility` (boolean, `getargbool 0 live.accessibility`).

```sh
if getargbool 0 live.accessibility; then
    [ -d "${NEWROOT}/etc/sv/espeakup" ] && ln -s "/etc/sv/espeakup" "${NEWROOT}/etc/runit/runsvdir/current/"
    [ -d "${NEWROOT}/etc/sv/brltty" ]   && ln -s "/etc/sv/brltty"   "${NEWROOT}/etc/runit/runsvdir/current/"
fi
```

Symlinks the runit service dirs into `runsvdir/current` (the live runsvdir,
not `default` — see `getty-serial.sh` below which uses `default`; this
inconsistency is in the source as-is). Only takes effect if the packages
providing `/etc/sv/espeakup` and `/etc/sv/brltty` were actually installed into
the ISO. `mklive.sh`'s "with speech" boot menu entries pass
`live.accessibility live.autologin` together (see bottom of this doc).

### getty-serial.sh

Purpose: enables a serial-console getty service matching the `console=`
kernel argument, so serial installs/boots get a login prompt.

Runs at `pre-pivot` priority 02 (parallel with the DM-autologin script).

Knob: `console` (standard kernel arg, inspected via `getarg console`, matched
against `*ttyS0*`, `*hvc0*`, `*hvsi0*`).

```sh
case "$CONSOLE" in
*ttyS0*)  ln -s /etc/sv/agetty-ttyS0  ${NEWROOT}/etc/runit/runsvdir/default/ ;;
*hvc0*)   ln -s /etc/sv/agetty-hvc0   ${NEWROOT}/etc/runit/runsvdir/default/ ;;
*hvsi0*)  ln -s /etc/sv/agetty-hvsi0  ${NEWROOT}/etc/runit/runsvdir/default/ ;;
esac
```

Gotcha: only these three exact console names are recognized; other serial
device names (`ttyUSB0`, `ttyAMA0`, etc.) are silently ignored. Requires the
matching `/etc/sv/agetty-*` service to exist in the rootfs already (from the
base package set).

### locale.sh

Purpose: sets the live system's language/locale and console keymap.

Runs at `pre-pivot` priority 03.

Knobs: `locale.LANG` (default `en_US.UTF-8`), `vconsole.keymap` (default
`us`). Writes `$NEWROOT/etc/locale.conf` (`LANG=`, plus hardcoded
`LC_COLLATE=C`). For keymap, patches `KEYMAP=` in `$NEWROOT/etc/vconsole.conf`
if present, else falls back to patching `$NEWROOT/etc/rc.conf` (older
Void/runit layout without vconsole.conf).

### mtd.sh + 59-mtd.rules + 61-mtd.rules

Purpose: supports booting the live squashfs from MTD/memdisk-backed media
(e.g. certain embedded/flash boot setups) instead of a normal block device.

`mtd.sh` runs at `pre-udev` priority 01 (earlier than everything else in this
module — it must run before udev processes block devices, since it's
registering a *new* udev rule for a device that doesn't exist yet).

```sh
MEMDISK=$(memdiskfind)
if [ "$MEMDISK" ]; then
    modprobe phram phram=memdisk,$MEMDISK
    modprobe mtdblock
    printf 'KERNEL=="mtdblock0", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/dmsquash-live-root /dev/mtdblock0"\n' \
        >> /etc/udev/rules.d/99-live-squash.rules
fi
```

It only does anything if `memdiskfind` locates an in-memory disk image (BIOS
INT 13h memdisk, e.g. from a legacy PXE/floppy-emulation boot path); loads
`phram` (parallel flash emulation over RAM) and `mtdblock` (block device
wrapper for MTD), then appends a udev rule that, once `mtdblock0` shows up,
triggers dracut's live-root discovery against it.

`59-mtd.rules` and `61-mtd.rules` are static udev rules copied in via
`inst_rules` + `prepare_udev_rules` in `module-setup.sh` (only when
`/usr/bin/memdiskfind` exists on the *build host*, gating this whole feature
at build time, not just boot time):
- `59-mtd.rules`: for `mtdblock[0-9]*` block devices, runs `IMPORT BLKID` so
  udev/blkid metadata (filesystem type, UUID, label) gets populated for them,
  same as any other block device.
- `61-mtd.rules`: extends the by-path/by-uuid/by-label symlink generation
  (normally block-device-only) to also match `mtdblock*` devices, so
  `/dev/disk/by-uuid/...` etc. work for MTD block devices too.

This whole subsystem is niche — irrelevant unless targeting MTD/flash-backed
boot media. Gotcha: it's silently skipped at build time if the build host
lacks `/usr/bin/memdiskfind`, so its presence in a built initramfs is
host-dependent, not guaranteed by the source tree alone.

### nomodeset.sh

Purpose: when booting with `nomodeset` (no native KMS/graphics driver mode
requested — e.g. broken GPU driver fallback), disables the graphical display
managers so the system doesn't try to start X/Wayland against a driver that
can't do modesetting.

Runs at `pre-pivot` priority 05 (last of the vmklive hooks).

Knob: `nomodeset` (boolean, standard kernel arg, `getargbool 0 nomodeset`).

```sh
if getargbool 0 nomodeset; then
    for dm in lightdm sddm gdm; do
        if [ -e "${NEWROOT}/etc/sv/${dm}" ]; then
            :> "${NEWROOT}/etc/sv/${dm}/down"
        fi
    done
fi
```

Creates a runit `down` file in the DM's service dir, which tells runit not to
(re)start that service. This is a runit convention: an empty `down` file next
to a service's `run` script means "don't autostart this service." Effect:
booting with `nomodeset` drops you to a text console (tty1, with whatever
autologin `adduser.sh`/`live.autologin` configured) instead of a graphical
session, regardless of which DM is installed. Note **lxdm is not in this
list** — an lxdm-based ISO booted with `nomodeset` will still try to start
lxdm.

`mklive.sh` ships a boot-menu entry ("graphics disabled") that passes
`nomodeset` for exactly this purpose.

---

## dracut/autoinstaller/ — unattended install (VAI)

### module-setup.sh

Purpose: assembles the autoinstaller module — installs everything needed to
partition a disk, fetch/parse a config, and run a full unattended Void install
from within the initramfs, then registers its hooks.

```sh
depends() { echo network; }   # needs dracut's network module (dhcp, etc.)

install() {
    inst .../chroot chmod chpasswd dhclient dhclient-script halt install jq \
         lsblk mkfs.ext4 mkswap mount resolvconf sfdisk sync xbps-install \
         xbps-uhelper xbps-query
    inst_multiple /var/db/xbps/keys/* /usr/share/xbps.d/*
    inst_multiple /etc/ssl/certs/*
    inst /etc/ssl/certs.pem

    inst_hook pre-mount 01 "$moddir/install.sh"
    inst_hook cmdline 99 "$moddir/parse-vai-root.sh"
    inst "$moddir/autoinstall.cfg" /etc/autoinstall.default
}
```

Two hooks, two different stages:
- `cmdline` priority 99 (`parse-vai-root.sh`) — runs very late in dracut's
  `cmdline` hook phase, where dracut is still deciding what the boot root
  device/spec is.
- `pre-mount` priority 01 (`install.sh`) — runs early in `pre-mount`, before
  dracut tries to mount whatever root it resolved (which, for `root=vai`,
  isn't a real block device at all — the "install" *becomes* the root
  resolution).

Also installs the module's default config as `/etc/autoinstall.default`
inside the initramfs (not `/etc/autoinstall.cfg` — that name is reserved for
whatever config the running install actually loads, so the shipped default
doesn't get clobbered before it's copied).

### parse-vai-root.sh

Purpose: tells dracut "yes, this is a resolvable root" when the kernel
cmdline requests the autoinstaller.

```sh
#!/bin/sh
if [ "${root}" = "vai" ] ; then
    rootok=1
fi
```

This is the entire file. Setting `rootok=1` is the dracut convention that
allows the boot to proceed to `pre-mount`/mount-root without dracut
complaining that no matching root device was found — because `root=vai`
never actually resolves to a device. Knob: `root=vai` on the kernel cmdline is
what activates the autoinstaller path being reachable at all (in combination
with the `auto` boolean checked inside `install.sh`, see below).

### install.sh

Purpose: the actual autoinstaller implementation — a shell library of
`VAI_*` functions plus a `VAI_main` driver that partitions a disk, installs
Void base-system via xbps, creates a user, installs grub, and performs an end
action (reboot/shutdown/custom script/custom function). Adapted from Void's
`mklive.sh`-bundled interactive installer, but fully scripted/unattended.

Gating: only runs at all if `auto` boolean cmdline arg is set:
```sh
if getargbool 0 auto ; then
    set -e
    VAI_main
    set +e
fi
```
So both `root=vai` (satisfies dracut's root check) and `auto` (actually
triggers the install) are needed together on the kernel cmdline in practice
for this flow. `root=vai` without `auto` would still let boot proceed past the
root-resolution check but never runs the installer, likely stalling later.

Config resolution — this is the "where does autoinstall.cfg come from" logic,
inside `VAI_configure_autoinstall()`:
```sh
if getargbool 0 autourl ; then
    xbps-uhelper fetch "$(getarg autourl)>/etc/autoinstall.cfg"
else
    mv /etc/autoinstall.default /etc/autoinstall.cfg
fi
if [ -f /etc/autoinstall.cfg ] ; then
    . ./etc/autoinstall.cfg
fi
```
Knobs:
- `autourl=<url>` — if set, fetches the config from that URL via
  `xbps-uhelper fetch` (any scheme xbps-uhelper supports) and uses it as
  `/etc/autoinstall.cfg`.
- Otherwise falls back to the module's bundled default
  (`/etc/autoinstall.default`, i.e. `dracut/autoinstaller/autoinstall.cfg` as
  shipped), renamed into place.
- The config file is a shell script that gets **sourced** (`. ./etc/autoinstall.cfg`),
  not parsed as data — it's expected to set shell variables (`disk`,
  `hostname`, `timezone`, `keymap`, `username`, `password`, `end_action`,
  etc.) and can also override `disk_expr`/`hostname_expr` (jq filters) or
  define an `end_function`. Because it's sourced as shell, an autoinstall.cfg
  fetched from `autourl` is arbitrary code execution in the installer
  environment by design — treat the URL source as trusted, there's no
  signature/integrity check.

Defaults if unset: disk = first block device from `lsblk --json`, hostname =
derived from the first "up" interface's global-scope IP address (via `ip
--json -r a` + jq), target=`/mnt`, timezone=`America/Chicago`, keymap=`us`,
libclocale=`en_US.UTF-8`, username=`voidlinux`, end_action=`shutdown`,
xbpsrepository resolved from `xbps-uhelper arch` (musl vs glibc repo URL).

`VAI_add_user` always uses `/bin/bash` and group set
`wheel,users,audio,video,cdrom,input` (hardcoded, not derived from
`live.user`/`vmklive`'s adduser.sh — the autoinstaller's target-system user
setup is independent of the live-session user created by `vmklive`). If
`password` is unset in the config, `passwd` is run interactively — meaning an
"unattended" install without a configured password will actually block on a
prompt.

`VAI_main` is a strictly linear 17-step sequence (partition → format → mount →
copy keys → install base-system+grub via xbps → sudo → hostname → rc.conf →
chroot binds → fix `/` ownership → add user → grub-install → fstab → locale →
end action). No DE/display-manager installation happens here — `pkgs` in the
config can list additional packages to pull in via xbps, so a DE/DM is only
installed if explicitly listed in `pkgs`; the autoinstaller does not
configure a DM or autologin the way `vmklive`'s scripts do. A target system
built via VAI will have no default graphical login setup unless the operator
added and configured one via `pkgs` + `end_script`/`end_function`.

### autoinstall.cfg

Purpose: shipped default/example config, entirely commented out — every
setting documents its own default inline (see `install.sh` defaults above)
and this file makes no changes on its own. Renamed to
`/etc/autoinstall.default` at module-install time, then copied to
`/etc/autoinstall.cfg` at boot if no `autourl` is given.

Gotcha: since every line is commented, editing this file to actually
customize a build requires uncommenting the relevant `key=value` lines — just
changing values while they're still commented has no effect.

---

## dracut/netmenu/ — PXE network-boot menu (not part of the ISO build)

### module-setup.sh

Purpose: builds a small dracut module that presents a `dialog`-based boot
menu (Install / Shell) for PXE/network-boot environments, and bundles the
full interactive `void-installer` script so it can be launched directly from
the initramfs.

```sh
depends() { echo network; }

install() {
    inst ... awk bash cat cfdisk chroot clear cut cp dhcpcd dialog echo env find \
        grep head id ln ls lsblk mke2fs mkfs.btrfs mkfs.f2fs mkfs.vfat mkfs.xfs \
        mkswap mktemp mount reboot rm sed sh sort sync stdbuf sleep touch xargs \
        xbps-install xbps-reconfigure xbps-remove xbps-uhelper
    ...
    sed -i '/Packages from ISO image/d' "$moddir/installer.sh"
    sed -i "s:shutdown -r now:sync && reboot -f:" "$moddir/installer.sh"
    inst "$moddir/installer.sh" /usr/bin/void-installer
    inst_hook pre-mount 05 "$moddir/netmenu.sh"
}
```

Gotcha / important build detail: this script references `$moddir/installer.sh`,
but `dracut/netmenu/` only contains `netmenu.sh` and `module-setup.sh` — there
is **no `installer.sh` in this directory**. The file it means is the
repo-root `installer.sh` (Void's full interactive TUI installer, ~1600
lines). It only ends up at `$moddir/installer.sh` because the *caller*
(`mknet.sh`, the PXE tarball builder) copies it there explicitly before
invoking dracut:
```sh
# mknet.sh
mkdir -p "$ROOTFS/usr/lib/dracut/modules.d/05netmenu"
cp dracut/netmenu/* "$ROOTFS/usr/lib/dracut/modules.d/05netmenu/"
cp installer.sh "$ROOTFS/usr/lib/dracut/modules.d/05netmenu/"   # <-- makes $moddir/installer.sh exist
```
So `dracut/netmenu/module-setup.sh` is **not self-contained** — it only works
as part of the `mknet.sh` PXE build flow, which stages the extra file first.
Running dracut against `dracut/netmenu/` in isolation (e.g. from `mklive.sh`,
which never copies or force-adds this module at all) would fail at the `sed
-i` step because the file wouldn't exist. **This module plays no role in the
ISO (`mklive.sh`) build** — only in `mknet.sh` (PXE tarball).

### netmenu.sh

Purpose: the actual boot-time menu, run at `pre-mount` priority 05 (in the PXE
initrd only).

```sh
dialog --colors --keep-tite --no-shadow --no-mouse \
       --backtitle "...Void Linux installation..." \
       --cancel-label "Reboot" --aspect 20 \
       --menu "Select an Action:" 10 50 2 \
       "Install" "Run void-installer" \
       "Shell" "Run dash" \
       2>/tmp/netmenu.action

case $(cat /tmp/netmenu.action) in
    "Install") /usr/bin/void-installer ; exec sh ;;
    "Shell") exec sh ;;
esac
```

Two options: launch the full interactive installer (`/usr/bin/void-installer`,
staged as described above) or drop to a shell. Cancel reboots. No autologin,
no DE/DM concerns — this runs before any root filesystem exists; it's purely
about getting an interactive install started over the network. The
`autoinstaller` module (force-added alongside `netmenu` in `mknet.sh`, with
higher priority — `01autoinstaller` vs `05netmenu`) can pre-empt this menu
entirely if `root=vai auto` is on the PXE cmdline, since the autoinstaller's
`cmdline`/`pre-mount` hooks run earlier.

---

## Where the default DE/session actually comes from — summary

Two independent things need to line up for "what desktop shows up by
default":

1. **Which DM/DE packages are installed and which DM's runit service is
   enabled** — decided entirely at build time by `mklive.sh` package
   selection (`-S` flag / package lists), not by anything in `dracut/`.
   `nomodeset.sh` can only turn a DM *off* (via a runit `down` file) at boot
   time; nothing in `dracut/` turns one on.
2. **Which user gets auto-logged-in, and (for lxdm/SDDM) which session that
   DM launches** — decided by `dracut/vmklive/display-manager-autologin.sh`
   at every boot, unconditionally (not gated by `live.autologin` — that flag
   only affects the tty1 text console via `adduser.sh`). For SDDM the session
   is hardcoded to `plasma.desktop`; for lightdm it's read from
   `/etc/lightdm/.session` (a file this module does not create); for lxdm
   it's probed by binary presence in a fixed fallback order; for GDM it isn't
   set here at all (GDM/GNOME decides its own default session once the user
   is auto-logged-in).

To change the default graphical session on an already-configured ISO, look
first at `display-manager-autologin.sh` for the DM in use (or, for lightdm,
`/etc/lightdm/.session`). To change whether a graphical session appears at
all versus a text console, check `nomodeset.sh` (only disables lightdm/sddm/
gdm, not lxdm) and the `live.autologin`/`nomodeset` boot args on the grub menu
entry used. The default grub entries in `mklive.sh` (`generate_grub_efi_boot`)
do **not** pass `live.autologin` except on the three "with speech" (a11y)
entries — plain boot entries get graphical DM autologin (from
`display-manager-autologin.sh`, which is unconditional) but not tty1 text
autologin.
