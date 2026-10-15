#!/bin/bash
# Tier: static. Builds the root-helper package in a scratch copy of this checkout and inspects what it would install.
# No root, nothing is installed, the checkout is not modified. Guards the promises in the README and in the
# marketplace submission: exactly these files, root-owned, no sudoers rule, no downloads, a polkit policy tied to one helper.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
command -v makepkg >/dev/null || suite_skip "makepkg is not installed"
command -v bsdtar >/dev/null || suite_skip "bsdtar is not installed"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# the PKGBUILD reads files relative to its own folder, so build from a scratch copy
mkdir "$tmp/src"
tar -C "$ROOT" --exclude=.git --exclude=.claude --exclude=packaging/src --exclude=packaging/pkg --exclude='*.pkg.tar.*' -cf - . | tar -C "$tmp/src" -xf -
( cd "$tmp/src/packaging" && PKGDEST="$tmp/out" makepkg -f -d --noconfirm >"$tmp/build.log" 2>&1 )
pkg=$(ls "$tmp"/out/*.pkg.tar.* 2>/dev/null | head -1)
if [ -z "$pkg" ]; then bad "the package builds (makepkg; dependencies not required)"; tail -5 "$tmp/build.log"; finish; exit 1; fi
ok "the package builds (makepkg; dependencies not required)"

echo "-- what it installs"
files=$(pacman -Qlp "$pkg" | awk '{print $2}' | grep -v '/$' | sort)
expected=$(printf '%s\n' \
  /usr/lib/modprobe.d/omarchy-fan.conf \
  /usr/lib/omarchy-fan/helper \
  /usr/lib/systemd/system/thinkfan.service.d/omarchy-fan.conf \
  /usr/share/licenses/omarchy-fan-helper/LICENSE \
  /usr/share/omarchy-fan/profiles/balanced.yaml \
  /usr/share/omarchy-fan/profiles/performance.yaml \
  /usr/share/omarchy-fan/profiles/quiet.yaml \
  /usr/share/polkit-1/actions/org.omarchy.fan.policy | sort)
t "exactly the documented files, nothing else" "$files" "$expected"
t "everything is under /usr (nothing in /etc or /home)" "$(echo "$files" | grep -vc '^/usr/')" 0
t "no sudoers file" "$(echo "$files" | grep -ci sudoers)" 0

echo "-- ownership and modes (from the archive)"
listing=$(bsdtar -tvf "$pkg")
mode_of() { echo "$listing" | awk -v f="$1" '$NF==f{print $1, $3, $4}'; }
t "the helper is executable and owned by root" "$(mode_of usr/lib/omarchy-fan/helper)" "-rwxr-xr-x root root"
t "the polkit policy is read-only, owned by root" "$(mode_of usr/share/polkit-1/actions/org.omarchy.fan.policy)" "-rw-r--r-- root root"
t "a curve is read-only, owned by root" "$(mode_of usr/share/omarchy-fan/profiles/balanced.yaml)" "-rw-r--r-- root root"
t "the thinkfan drop-in is read-only, owned by root" "$(mode_of usr/lib/systemd/system/thinkfan.service.d/omarchy-fan.conf)" "-rw-r--r-- root root"

echo "-- contents"
mkdir "$tmp/x" && bsdtar -xf "$pkg" -C "$tmp/x" 2>/dev/null
cmp -s "$tmp/x/usr/lib/omarchy-fan/helper" "$ROOT/helper/omarchy-fan-helper" && ok "the packaged helper is the one in this checkout" || bad "the packaged helper differs from helper/omarchy-fan-helper"
same=1; for p in quiet balanced performance; do cmp -s "$tmp/x/usr/share/omarchy-fan/profiles/$p.yaml" "$ROOT/profiles/$p.yaml" || same=0; done
[ $same = 1 ] && ok "the packaged curves are the ones in profiles/" || bad "a packaged curve differs from profiles/"
t "the helper does not use sudo, sudoers, NOPASSWD, curl or wget" "$(grep -ciE 'sudo|nopasswd|curl|wget' "$tmp/x/usr/lib/omarchy-fan/helper")" 0
t "the modprobe option is exactly fan_control=1" "$(cat "$tmp/x/usr/lib/modprobe.d/omarchy-fan.conf")" "options thinkpad_acpi fan_control=1"
drop=$(cat "$tmp/x/usr/lib/systemd/system/thinkfan.service.d/omarchy-fan.conf")
t "thinkfan's service lifts the restart rate limit" "$(echo "$drop" | grep -c '^StartLimitIntervalSec=0$')" 1
t "thinkfan's service runs ensure-module first, and a failure there can't stop it" "$(echo "$drop" | grep -c '^ExecStartPre=-/usr/lib/omarchy-fan/helper ensure-module$')" 1
t "the package does not override thinkfan's own arguments" "$(echo "$drop" | grep -c 'THINKFAN_ARGS')" 0

echo "-- the polkit policy"
pol="$tmp/x/usr/share/polkit-1/actions/org.omarchy.fan.policy"
t "one action, org.omarchy.fan.control" "$(grep -o '<action id="[^"]*"' "$pol")" '<action id="org.omarchy.fan.control"'
t "it is tied to the one helper path" "$(grep -o 'exec.path">[^<]*' "$pol" | sed 's/.*>//')" /usr/lib/omarchy-fan/helper
t "remote and inactive sessions are refused" "$(grep -cE '<allow_(any|inactive)>no<' "$pol")" 2
t "only a local active session is allowed without a password" "$(grep -c '<allow_active>yes<' "$pol")" 1

echo "-- package metadata"
info_out=$(pacman -Qip "$pkg" 2>/dev/null)
field() { echo "$info_out" | awk -F' *: ' -v k="$1" '$1==k{print $2}'; }
t "package name" "$(field Name)" omarchy-fan-helper
t "license" "$(field Licenses)" MIT
t "it depends on thinkfan and polkit" "$(field 'Depends On' | tr ' ' '\n' | grep -cE '^(thinkfan|polkit)$')" 2
echo "$(field Version)" | grep -qE '^[0-9]+(\.[0-9]+)*-[0-9]+$' && ok "version looks right: $(field Version)" || bad "odd version: $(field Version)"

echo "-- the copy installed on this machine (if any)"
if pacman -Q omarchy-fan-helper >/dev/null 2>&1; then
  t "no installed file of the package is missing or altered" "$(pacman -Qkk omarchy-fan-helper 2>&1 | grep -c ' 0 altered files')" 1
  cmp -s /usr/lib/omarchy-fan/helper "$ROOT/helper/omarchy-fan-helper" && ok "the installed helper matches this checkout" \
    || info "the installed helper differs from this checkout (reinstall the package to test this checkout's helper)"
else
  skip "installed-package checks (the package is not installed here)"
fi

finish
