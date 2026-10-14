#!/bin/bash
# Tier: destructive. Needs passwordless sudo (or root) and an idle, cool laptop. Stops and kills thinkfan on purpose to
# check what happens to the fan, then starts it again and restores your profile (also if interrupted).
# The README promises that "systemctl disable --now thinkfan" gives the fan back to the firmware; this checks it.
# It also records what happens if thinkfan is killed instead of stopped; we make no promise about that, so a bad
# result there is reported as a known gap, not a failure.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$1" ] && CLI=$1
is_thinkpad || suite_skip "not a ThinkPad"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
if [ "$(id -u)" = 0 ]; then S() { "$@"; }; else
  sudo -n true 2>/dev/null || suite_skip "needs passwordless sudo (or run as root)"
  S() { sudo -n "$@"; }
fi
start_temp=$(cpu_temp)
[ "${start_temp:-99}" -le 65 ] || suite_skip "the CPU is warm (${start_temp}C): run this on an idle laptop (<= 65C)"

orig=$("$CLI" current)
restore() {
  S systemctl reset-failed thinkfan >/dev/null 2>&1
  S systemctl start thinkfan >/dev/null 2>&1; sleep 2
  case "$orig" in manual) "$CLI" manual "$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1
}
trap restore EXIT

echo "-- a clean stop (what 'systemctl disable --now thinkfan' does): the fan goes back to the firmware"
"$CLI" manual 0; sleep 3
t "before: thinkfan holds the fan at level 0" "$(fan_level)" 0
S systemctl stop thinkfan; sleep 3
t "thinkfan is stopped" "$(systemctl is-active thinkfan)" inactive
t "after a clean stop the fan is back on automatic (firmware) control" "$(fan_level)" auto

echo "-- starting again takes the fan back"
S systemctl start thinkfan; sleep 3
t "thinkfan is running again" "$(systemctl is-active thinkfan)" active
t "thinkfan holds the fan again (level 0)" "$(fan_level)" 0
t "the plugin reports it is ready" "$(setup_state)" ready

echo "-- a crash (kill -9): nothing gets to clean up"
pid=$(pidof thinkfan)
S kill -9 $pid; sleep 5
lvl=$(fan_level); state=$(systemctl is-active thinkfan)
if [ "$lvl" = auto ]; then
  ok "after thinkfan is killed the fan is back on automatic control"
else
  gap "after thinkfan is killed the fan stays at level $lvl (not automatic): nothing restores firmware control, and thinkfan is $state. Only the laptop's own emergency thermal protection is left until someone runs 'sudo systemctl start thinkfan'"
fi
[ "$state" = active ] && ok "systemd restarted thinkfan on its own" || gap "systemd does not restart thinkfan after a crash (thinkfan.service has no Restart= policy)"
S systemctl reset-failed thinkfan >/dev/null 2>&1; S systemctl start thinkfan; sleep 3
t "a plain 'systemctl start thinkfan' recovers it" "$(systemctl is-active thinkfan)" active
t "and the fan is under control again (a numbered level, not automatic)" "$(fan_level | grep -cE '^[0-8]$|^disengaged$')" 1

t "the CPU stayed cool throughout (under 75C; started at ${start_temp}C)" "$([ "$(cpu_temp)" -lt 75 ] && echo yes || echo "no ($(cpu_temp))")" yes

finish
