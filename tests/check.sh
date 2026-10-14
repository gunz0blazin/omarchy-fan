#!/bin/bash
# Static checks, no hardware needed.
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
rc=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; rc=1; }

command -v omarchy >/dev/null && { omarchy plugin validate . >/dev/null 2>&1 && ok "plugin manifest validates" || bad "plugin manifest validates"; }
for f in bin/omarchyfan bin/omarchy-fan-follow helper/omarchy-fan-helper install-helper.sh packaging/PKGBUILD; do
  bash -n "$f" 2>/dev/null && ok "syntax $f" || bad "syntax $f"
done
for f in bin/omarchyfan bin/omarchy-fan-follow helper/omarchy-fan-helper install-helper.sh; do
  [ -x "$f" ] && ok "executable $f" || bad "executable $f"
done
if command -v groff >/dev/null; then
  [ -z "$(groff -man -ww -z man/omarchyfan.1 2>&1)" ] && ok "man page has no groff warnings" || bad "man page has no groff warnings"
fi
for y in profiles/*.yaml; do
  grep -q '^levels:' "$y" && grep -q 'tpacpi: /proc/acpi/ibm/fan' "$y" && ok "profile $y" || bad "profile $y"
done
qml=$(command -v qmllint || ls /usr/lib/qt6/bin/qmllint 2>/dev/null | head -1)
[ -n "$qml" ] && { "$qml" Panel.qml 2>&1 | grep -qiE 'syntax|expected' && bad "qml lint Panel.qml" || ok "qml lint Panel.qml"; }
! grep -rn 'decepticon\|ThemePalette\|TransformFx' Panel.qml >/dev/null && ok "no theme-specific dependencies" || bad "no theme-specific dependencies"
xmllint --noout helper/org.omarchy.fan.policy 2>/dev/null && ok "polkit policy is valid XML" || echo "  skip  xmllint not available"
exit $rc
