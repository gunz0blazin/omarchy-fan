#!/bin/bash
# Tier: shell. Needs the plugin enabled in your running Omarchy bar. Opens and closes the panel, presses Escape, then
# (unless SKIP_CYCLE=1) disables and re-enables the plugin, which is the guide's own "before sharing, test" list:
# click/open, Escape, open and close, disable, re-enable, restart, removal. qmllint cannot see runtime errors; this can.
# The bar flickers for a few seconds during the disable/enable cycle; the icon is put back in the same spot.
# Don't press keys or click while it runs (it sends an Escape key press to whatever window has focus).
. "$(dirname "$(readlink -f "$0")")/lib.sh"
is_thinkpad || suite_skip "not a ThinkPad (the widget hides itself)"
for c in omarchy quickshell hyprctl jq; do command -v $c >/dev/null || suite_skip "$c is not installed"; done
[ "$(plugin_state)" = enabled ] || suite_skip "the plugin is not enabled in the bar (state: '$(plugin_state)')"
Q="quickshell ipc -p /usr/share/omarchy/shell"
SHELLJSON=$HOME/.config/omarchy/shell.json

# the open panel is a layer surface called omarchy-keyboard-panel; counting them tells us from outside if it is open
panels() { hyprctl layers -j 2>/dev/null | jq '[.. | objects | select(.namespace? == "omarchy-keyboard-panel")] | length'; }
where() { jq -r --arg id "$ID" '.bar.layout | to_entries[] | .key as $s | (.value | map(.id) | index($id)) as $i | select($i != null) | "\($s) \($i)"' "$SHELLJSON"; }

echo "-- the plugin is loaded and reachable"
t "the plugin is enabled" "$(plugin_state)" enabled
ipc=$($Q show 2>/dev/null | awk -v id="$ID" '$1=="target"{on=($2==id)} on')
t "an IPC target is registered for it" "$(echo "$ipc" | grep -c "^target $ID\$")" 1
for fn in open close toggle; do t "IPC function: $fn" "$(echo "$ipc" | grep -c "function $fn()")" 1; done
t "the command works" "$("$CLI" status 2>/dev/null | head -1 | grep -c '^profile:')" 1
t "exactly one follower is running" "$(follower_count)" 1

echo "-- the panel opens and closes (counted as layer surfaces)"
ts=$(date '+%Y-%m-%d %H:%M:%S')
n0=$(panels)
$Q call "$ID" open >/dev/null 2>&1; sleep 1.5
t "open: the panel appears" "$(panels)" $((n0+1))
if command -v wtype >/dev/null; then
  wtype -k Escape; sleep 1.2
  t "Escape closes it" "$(panels)" "$n0"
else
  skip "Escape closes it (wtype is not installed)"
  $Q call "$ID" close >/dev/null 2>&1; sleep 1
fi
$Q call "$ID" toggle >/dev/null 2>&1; sleep 1.2
t "toggle opens it" "$(panels)" $((n0+1))
$Q call "$ID" toggle >/dev/null 2>&1; sleep 1.2
t "toggle closes it" "$(panels)" "$n0"
$Q call "$ID" open >/dev/null 2>&1; sleep 1.2; $Q call "$ID" close >/dev/null 2>&1; sleep 1.2
t "close closes it" "$(panels)" "$n0"
for i in 1 2 3; do $Q call "$ID" toggle >/dev/null 2>&1; sleep 0.6; done; sleep 1; $Q call "$ID" close >/dev/null 2>&1; sleep 1
t "it still opens and closes cleanly after rapid toggling" "$(panels)" "$n0"

echo "-- the shell log has no errors from this plugin"
errs=$(journalctl --user --since "$ts" --no-pager 2>/dev/null | grep -i 'thinkpad-fan' | grep -iE 'error|TypeError|ReferenceError|unable to|is not defined|cannot|failed to' | cut -c1-200)
t "no QML or runtime errors mention the plugin since the test began" "$(echo -n "$errs" | grep -c .)" 0
[ -n "$errs" ] && echo "$errs" | head -3 | sed 's/^/        /'

if [ "${SKIP_CYCLE:-0}" = 1 ]; then
  skip "disable / re-enable cycle (SKIP_CYCLE=1)"
else
  echo "-- disable and re-enable (the bar flickers; the icon is put back where it was)"
  read -r sec idx <<<"$(where)"
  restore_bar() {
    [ "$(plugin_state)" = enabled ] || omarchy plugin enable "$ID" >/dev/null 2>&1
    sleep 2
    [ -n "$sec" ] && omarchy bar move "$ID" --section "$sec" --index "$idx" >/dev/null 2>&1
  }
  trap restore_bar EXIT
  omarchy plugin disable "$ID" >/dev/null 2>&1; sleep 4
  t "disabled: the plugin is listed as disabled" "$(plugin_state)" disabled
  t "disabled: the follower has stopped" "$(follower_count)" 0
  t "disabled: the icon is gone from the bar" "$(where | wc -l)" 0
  omarchy plugin enable "$ID" >/dev/null 2>&1; sleep 6
  t "re-enabled: the plugin is listed as enabled" "$(plugin_state)" enabled
  t "re-enabled: exactly one follower is running" "$(follower_count)" 1
  t "re-enabled: the command still works" "$("$CLI" status 2>/dev/null | head -1 | grep -c '^profile:')" 1
  restore_bar; trap - EXIT; sleep 1
  t "the icon is back in the same bar section and position (was: $sec #$idx)" "$(where)" "$sec $idx"
  $Q call "$ID" open >/dev/null 2>&1; sleep 1.5
  t "the panel opens after the cycle" "$(panels)" $((n0+1))
  $Q call "$ID" close >/dev/null 2>&1; sleep 1.2
  t "and closes again" "$(panels)" "$n0"
fi

finish
