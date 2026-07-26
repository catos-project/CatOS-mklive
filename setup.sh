#!/usr/bin/env bash
# CatOS build environment setup — run once per machine, from the repo root
set -euo pipefail

# xbps ships built-in on Void; other distros (Ubuntu etc.) need the static binaries.
# Installed to /usr/local/bin (not ~/.local) so they're also on root's PATH under sudo,
# which mkiso.sh needs to run as.
if ! command -v xbps-install &> /dev/null; then
    curl -LO https://repo-default.voidlinux.org/static/xbps-static-latest.x86_64-musl.tar.xz
    tar xf xbps-static-latest.x86_64-musl.tar.xz
    sudo mv usr/bin/* /usr/local/bin/
    rm -rf usr xbps-static-latest.x86_64-musl.tar.xz
fi
export XBPS_ARCH=x86_64   # required when static xbps runs on a glibc host

# The handful of host tools mkiso.sh needs that aren't Void packages
if command -v apt &> /dev/null; then
    sudo apt install -y squashfs-tools xorriso git make
else
    echo "Non-Debian host: install squashfs-tools, xorriso, git, make manually."
fi

make   # builds mklive's own small helper tools

echo
echo "Setup done. Build the ISO with:"
echo "  sudo ./mkiso.sh -b gnome -- -I ./branding -o catos.iso"
