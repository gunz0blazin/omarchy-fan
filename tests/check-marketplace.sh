#!/bin/bash
# Tier: static. Audits this checkout against the Omarchy plugin marketplace rules, so it can run before every release
# and again whenever the rules change. Reads files only (plus 'omarchy plugin validate' and qmllint).
#
# Sources of the rules (read 2026-10-14):
#   https://plugins.omarchy.org/publish.html   what a repository must contain
#   https://plugins.omarchy.org/develop.html   the development guide (manifest rules, panel conventions, README content)
#   SUBMISSION.md and SECURITY.md in https://github.com/omacom/omarchy-plugin-marketplace   id rules, security baseline
# FAIL = a rule. INFO = a suggestion from the guide's example that is not a rule.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$ROOT" || exit 1
m=manifest.json
[ -f "$m" ] || { bad "manifest.json exists in the repository root"; finish; exit 1; }

echo "-- repository contents (publish page)"
if command -v omarchy >/dev/null; then
  omarchy plugin validate . >/dev/null 2>&1 && ok "omarchy plugin validate exits clean" || bad "omarchy plugin validate exits clean"
else
  skip "omarchy plugin validate (the omarchy command is not installed)"
fi
for f in manifest.json README.md LICENSE; do [ -f "$f" ] && ok "$f is in the repository root" || bad "$f is missing from the repository root"; done
ep=$(jq -r '.entryPoints.barWidget // empty' $m)
[ -n "$ep" ] && [ -f "$ep" ] && ok "the entry point file exists, with the exact capitalization: $ep" || bad "entry point file missing or wrong case: '$ep'"
if [ -f preview.png ]; then
  bytes=$(stat -c %s preview.png); dims=$(file preview.png | grep -oE '[0-9]+ x [0-9]+' | head -1)
  w=${dims%% x*}; h=${dims##* x}
  [ "$bytes" -le $((50*1024*1024)) ] && [ $((w*h)) -le 40000000 ] && ok "preview.png is within the limits (50 MB, 40 megapixels): $dims, $bytes bytes" || bad "preview.png exceeds 50 MB / 40 megapixels"
else
  info "no preview.png (optional)"
fi

echo "-- manifest (development guide)"
for k in schemaVersion id name version kinds entryPoints; do jq -e "has(\"$k\")" $m >/dev/null && ok "required field: $k" || bad "required field missing: $k"; done
for k in author license description; do jq -e "has(\"$k\")" $m >/dev/null && ok "metadata field: $k" || bad "metadata field missing: $k"; done
v=$(jq -r .version $m); [ ${#v} -le 64 ] && ok "version '$v' is within 64 characters" || bad "version is longer than 64 characters"
id=$(jq -r .id $m)
case "$id" in omarchy.*) bad "id '$id' uses the reserved omarchy.* namespace" ;; *) ok "id '$id' is outside the reserved omarchy.* namespace" ;; esac
echo "$id" | grep -qE '^[a-z0-9][a-z0-9._-]*$' && ok "id is lowercase" || bad "id is not lowercase letters, digits, dots, hyphens"
echo "$id" | grep -qE '\.' && ok "id is namespaced (contains a dot)" || bad "id is not namespaced"
jq -e '(.omarchy // {}) | has("clonedFrom") | not' $m >/dev/null && ok "no omarchy.clonedFrom (clone-only field, must be removed before publishing)" || bad "omarchy.clonedFrom is still in the manifest"
jq -e '(.kinds | index("bar-widget") != null) and (.entryPoints.barWidget != null)' $m >/dev/null && ok "kind bar-widget has entryPoints.barWidget" || bad "kinds and entryPoints do not match"
jq -e '.barWidget | has("displayName") and has("category") and has("allowMultiple")' $m >/dev/null && ok "barWidget block has displayName, category, allowMultiple" || bad "barWidget block is incomplete"
jq -e '.barWidget | has("defaultSection")' $m >/dev/null && ok "barWidget.defaultSection is set (the guide's example has it)" || info "no barWidget.defaultSection (the guide's example has one; 'omarchy plugin add' would suggest the center)"

echo "-- plugin folder (development guide)"
if [ -d .git ] || git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  links=$(git -C "$ROOT" ls-files -s | awk '$1=="120000"' | wc -l)
else
  links=$(find "$ROOT" -type l | wc -l)
fi
t "no symlinks inside the plugin folder" "$links" 0

echo "-- panel conventions (development guide)"
q=$(command -v qmllint || ls /usr/lib/qt6/bin/qmllint 2>/dev/null | head -1)
if [ -n "$q" ] && [ -d /usr/share/omarchy/shell ]; then
  "$q" -I /usr/share/omarchy/shell "$ep" >/dev/null 2>&1; rc=$?
  t "qmllint -I \$OMARCHY_PATH/shell exits 0 for $ep" "$rc" 0
else
  skip "qmllint with the Omarchy include path (qmllint or /usr/share/omarchy/shell is missing)"
fi
grep -q "moduleName: \"$id\"" "$ep" && ok "moduleName equals the plugin id" || bad "moduleName does not equal the plugin id"
grep -q 'KeyboardPanel' "$ep" && grep -q 'PanelKeyCatcher' "$ep" && ok "uses KeyboardPanel and PanelKeyCatcher" || bad "does not use KeyboardPanel / PanelKeyCatcher"
grep -q 'onCloseRequested: root.close()' "$ep" && ok "Escape closes the panel (onCloseRequested)" || bad "nothing closes the panel on Escape"
grep -q 'onTabRequested.*switchPanel' "$ep" && ok "Tab goes through switchPanel" || bad "Tab is not routed through switchPanel"
grep -q 'Style.space' "$ep" && grep -q 'Style.font' "$ep" && ok "uses Style.space() and Style.font" || bad "does not use Style.space() / Style.font"
grep -rqE 'quickshell +(-p|--path)' "$ep" bin 2>/dev/null && bad "may start a second Quickshell process" || ok "never starts a second Quickshell process"
[ -f BarWidget.qml ] && ok "has BarWidget.qml" || info "no BarWidget.qml: this is a single-file bar widget (like the built-in agents plugin); the guide's example has BarWidget.qml + Panel.qml"

echo "-- README content (development guide: installation, usage, configuration, removal; disclose every dependency, privilege boundary, service, installer)"
for pair in "installation|Quick start|Install" "usage|CLI|Usage|Using" "configuration|Configuration" "removal|Uninstall|Remove|Removal"; do
  name=${pair%%|*}; pat=${pair#*|}
  grep -qiE "^#+ .*($pat)" README.md && ok "README section: $name" || bad "README has no $name section"
done
grep -q 'omarchy plugin add' README.md && ok "README shows how to add the plugin (omarchy plugin add)" || bad "README does not show 'omarchy plugin add'"
grep -q 'omarchy plugin remove' README.md && ok "README shows how to remove the plugin (omarchy plugin remove)" || bad "README does not show 'omarchy plugin remove'"
for w in thinkfan polkit pkexec makepkg modprobe systemd power-profiles-daemon install-helper sudo; do
  grep -qi -- "$w" README.md && ok "README discloses: $w" || bad "README does not mention: $w (a dependency, privilege boundary, service or installer)"
done
grep -qiE 'unsandboxed|not sandboxed' README.md && info "README mentions the unsandboxed warning" || info "README does not mention that plugins run unsandboxed (the marketplace says so itself)"

echo "-- security baseline patterns (SECURITY.md): these would be blocking findings"
code=$(ls bin/* helper/omarchy-fan-helper install-helper.sh packaging/PKGBUILD 2>/dev/null)
t "no 'curl | sh' or 'wget | sh' style downloads" "$(grep -ciE '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' $code | awk '{s+=$1} END{print s+0}')" 0
t "no sudoers rule is installed or written" "$(grep -ciE 'nopasswd|/etc/sudoers' $code | awk '{s+=$1} END{print s+0}')" 0
t "no pid read from a predictable /tmp file for privileged control" "$(grep -ciE 'pid.*/tmp/|/tmp/.*pid' $code | awk '{s+=$1} END{print s+0}')" 0
t "no cargo install --git / unpinned remote git execution" "$(grep -ciE 'cargo install --git|git clone' $code | awk '{s+=$1} END{print s+0}')" 0
info "expected to be flagged for a maintainer to review (not blocking): pkexec, makepkg/pacman (package manager), systemd drop-in (service management), install-helper.sh (installer)"

finish
