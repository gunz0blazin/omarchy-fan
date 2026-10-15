#!/bin/bash
# Installs the root half of ThinkPad Fan Control: thinkfan (AUR) and the omarchy-fan-helper
# package built from packaging/PKGBUILD, then turns fan control on. The fan panel's
# "Install fan control" button runs this in a terminal; you can also run it yourself.
set -e
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

[ -d /sys/devices/platform/thinkpad_acpi ] || { echo "This isn't a ThinkPad (no thinkpad_acpi), nothing to do."; exit 1; }

echo "==> thinkfan"
if command -v thinkfan >/dev/null; then echo "already installed"; else omarchy-pkg-aur-add thinkfan; fi

echo
echo "==> omarchy-fan-helper (built from $here/packaging/PKGBUILD)"
echo "It installs: /usr/lib/omarchy-fan/helper, a polkit policy, the three fan curves, and a modprobe + systemd drop-in."
echo "Read it first if you like: $here/helper/omarchy-fan-helper"
echo
# -f: a second run (after a cancelled install, or the panel's Update pressed twice) rebuilds instead of stopping at "already built"
(cd "$here/packaging" && makepkg -sif)

echo
echo "==> enabling fan control"
pkexec /usr/lib/omarchy-fan/helper enable

echo
echo "==> applying your fan profile with the installed curves"
"$here/bin/omarchyfan" reapply || true
echo
echo "Done. Open the fan icon in the bar."
