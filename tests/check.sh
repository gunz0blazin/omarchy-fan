#!/bin/bash
# Tier: static. Reads files only, no hardware, no system changes. Works on any branch of this repo.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$ROOT" || exit 1

if command -v omarchy >/dev/null; then
  omarchy plugin validate . >/dev/null 2>&1 && ok "plugin manifest validates (omarchy plugin validate)" || bad "plugin manifest validates (omarchy plugin validate)"
else
  skip "omarchy plugin validate (the omarchy command is not installed)"
fi

# every script in the repo: bash syntax, and executable if it is meant to be run
# (LEGACY: bin/omarchy-fan is the old command name and is picked up here automatically; it goes away with the name)
scripts="bin/* helper/omarchy-fan-helper install-helper.sh tests/*.sh"
for f in $scripts; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null && ok "syntax $f" || bad "syntax $f"
  [ "$f" = tests/lib.sh ] || { [ -x "$f" ] && ok "executable $f" || bad "executable $f"; }
done
bash -n packaging/PKGBUILD 2>/dev/null && ok "syntax packaging/PKGBUILD" || bad "syntax packaging/PKGBUILD"

# optional, but worth having: shellcheck catches quoting and logic slips in bash
if command -v shellcheck >/dev/null; then
  shellcheck -S warning -e SC1090,SC1091,SC2086,SC2155 bin/* helper/omarchy-fan-helper install-helper.sh >/dev/null 2>&1 \
    && ok "shellcheck (warnings and above)" || bad "shellcheck (warnings and above)"
else
  skip "shellcheck (not installed: sudo pacman -S shellcheck)"
fi

# man pages (LEGACY: man/omarchy-fan.1 is the old command's page)
if command -v groff >/dev/null; then
  for m in man/*.1; do
    [ -f "$m" ] || continue
    [ -z "$(groff -man -ww -z "$m" 2>&1)" ] && ok "$m has no groff warnings" || bad "$m has no groff warnings"
  done
else
  skip "man page lint (groff is not installed)"
fi

for y in profiles/*.yaml; do
  grep -q '^levels:' "$y" && grep -q 'tpacpi: /proc/acpi/ibm/fan' "$y" && ok "profile $y has levels and the fan line" || bad "profile $y has levels and the fan line"
done

# safety net: every profile must put the fan at full speed by 86 C (the kernel powers the machine off at 98 C, and a load can
# heat this class of laptop by ~1 C per second). The last numbered level's upper limit is where full speed takes over.
for y in profiles/*.yaml; do
  top=$(awk '/^  - \[[0-9]+, *[0-9]+, *[0-9]+\]/{gsub(/[][,]/," "); last=$4} END{print last}' "$y")
  grep -q 'level full-speed' "$y" && [ -n "$top" ] && [ "$top" -le 86 ] \
    && ok "profile $y reaches full speed by ${top}C (limit 86C)" || bad "profile $y must have a full-speed row, entered by 86C at the latest (found: ${top:-none})"
done

# the panel offers "Update fan control" only when packaging/PKGBUILD's version goes up, so nothing the helper package installs
# (helper/, profiles/, the PKGBUILD's own package() lines) may change after the last pkgver/pkgrel bump without another one
pkgv() { awk -F= '/^pkgver=/{v=$2} /^pkgrel=/{r=$2} END{print v "-" r}'; }
last=$(git log -1 --format=%H -G'^pkg(ver|rel)=' -- packaging/PKGBUILD 2>/dev/null)
if [ -z "$last" ]; then
  skip "helper package version bump (no git history)"
elif [ "$(git show "$last:packaging/PKGBUILD" | pkgv)" != "$(pkgv < packaging/PKGBUILD)" ]; then
  ok "helper package: version raised to $(pkgv < packaging/PKGBUILD) (not committed yet)"
elif git diff --quiet "$last" -- helper profiles \
  && [ -z "$(git diff -U0 "$last" -- packaging/PKGBUILD | grep -E '^[+-][^+-]' | grep -vE '^[+-]pkg(ver|rel)=')" ]; then
  ok "helper package: nothing it installs changed since version $(pkgv < packaging/PKGBUILD)"
else
  bad "helper/, profiles/ or the PKGBUILD changed since helper version $(pkgv < packaging/PKGBUILD): raise pkgrel, or users never see 'Update fan control'"
fi

qml=$(command -v qmllint || ls /usr/lib/qt6/bin/qmllint 2>/dev/null | head -1)
if [ -n "$qml" ]; then
  "$qml" Panel.qml 2>&1 | grep -qiE 'syntax|expected' && bad "qmllint Panel.qml: no syntax errors" || ok "qmllint Panel.qml: no syntax errors"
else
  skip "qmllint (not installed)"
fi

grep -rn 'decepticon\|ThemePalette\|TransformFx' Panel.qml >/dev/null && bad "no theme-specific dependencies in Panel.qml" || ok "no theme-specific dependencies in Panel.qml"

if command -v xmllint >/dev/null; then
  xmllint --noout helper/org.omarchy.fan.policy 2>/dev/null && ok "polkit policy is valid XML" || bad "polkit policy is valid XML"
else
  skip "polkit policy XML check (xmllint is not installed)"
fi

finish
