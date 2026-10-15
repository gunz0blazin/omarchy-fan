#!/bin/bash
# Tier: shell. Needs the plugin running in the bar (the panel starts the follower) and the root helper installed.
# Changes your power profile, fan profile and follow flag while it runs, and restores all three (also if interrupted).
# Don't plug or unplug the charger meanwhile: Omarchy changes the power profile itself when you do.
# Optional $1: path to the command (default: the one in this checkout).
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$1" ] && CLI=$1
is_thinkpad || suite_skip "not a ThinkPad"
[ "$(plugin_state)" = enabled ] || suite_skip "the plugin is not enabled in the bar (the follower only runs there)"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"

orig_pp=$(powerprofilesctl get); orig_fan=$("$CLI" current)
orig_follow=$("$CLI" stats | awk -F'\t' '$1=="follow"{print $2}')
ac0=$(cat /sys/class/power_supply/AC/online 2>/dev/null)
restore() {
  powerprofilesctl set "$orig_pp" >/dev/null 2>&1; sleep 3
  case "$orig_fan" in manual) "$CLI" manual "$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)" ;; *) "$CLI" "$orig_fan" ;; esac >/dev/null 2>&1
  "$CLI" follow "$orig_follow" >/dev/null 2>&1
}
trap restore EXIT

t "exactly one follower is running" "$(follower_count)" 1

"$CLI" follow on; "$CLI" balanced; powerprofilesctl set balanced; sleep 2
powerprofilesctl set power-saver; sleep 5
t "follow on: power-saver -> quiet" "$("$CLI" current)" quiet
powerprofilesctl set performance; sleep 5
t "follow on: performance -> performance" "$("$CLI" current)" performance
"$CLI" manual 5; sleep 2
"$CLI" follow off
powerprofilesctl set balanced; sleep 5
t "follow off: the manual setting is kept" "$("$CLI" current)" manual
"$CLI" follow on
powerprofilesctl set power-saver; sleep 5
t "follow back on: power-saver -> quiet" "$("$CLI" current)" quiet
t "the charger was not plugged or unplugged during the test (results would be unreliable)" "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" "$ac0"

finish
