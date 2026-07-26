# branding/

Everything that turns a stock Void Linux image into a CatOS one lives here.

It's passed to `mklive.sh`/`mkiso.sh` with the `-I` flag:

```
sudo ./mkiso.sh -b gnome -- -I ./branding -o catos.iso
```

`-I` copies whatever is under this directory straight onto the ROOTFS, so
lay it out as a mirror of the target filesystem. For example:

```
branding/
  etc/
    os-release          # distro name/version (neofetch, fastfetch, etc. read this)
    motd
  usr/
    share/
      backgrounds/catos/...
  etc/skel/...           # default dotfiles for new users
```

Nothing else needs to change for these to take effect — `mklive.sh` copies
the whole tree in during the build.

## Not handled here

Two pieces of branding are wired up directly by the upstream scripts via
fixed paths, not through `-I`:

* Boot splash image — `data/splash.png` (see `mklive.sh`'s `SPLASH_IMAGE`)
* Live-session welcome text — `data/issue` (copied to `/etc/issue` by
  `mklive.sh`)

Replace those files in place rather than duplicating them here.

The bootloader title isn't a file at all — set it with `mklive.sh -T "CatOS"`
(see the [Customizing the image](../README.md#customizing-the-image) section
of the main README).
