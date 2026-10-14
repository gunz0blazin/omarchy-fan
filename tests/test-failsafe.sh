#!/bin/bash
# Tier: destructive. Needs passwordless sudo (or root) and an idle, cool laptop (<= 48C). Stops and kills thinkfan on
# purpose to check what happens to the fan, then starts it again and restores your profile (also if interrupted).
# Takes about five minutes: the ThinkPad's fan watchdog hands the fan back to the firmware 120 seconds after thinkfan
# last wrote to it, so each check has to wait for it. (Measured on a T480s: automatic control returns at ~120-125 s,
# whether thinkfan was stopped cleanly or killed.)
# The README promises that "systemctl disable --now thinkfan" gives the fan back to the firmware; this checks it.
# What happens after a crash is recorded too, but we promise nothing about it, so shortfalls there are known gaps,
# not failures.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$1" ] && CLI=$1
is_thinkpad || suite_skip "not a ThinkPad"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
if [ "$(id -u)" = 0 ]; then S() { "$@"; }; else
  sudo -n true 2>/dev/null || suite_skip "needs passwordless sudo (or run as root)"
  S() { sudo -n "$@"; }
fi
start_temp=$(cpu_temp)
[ "${start_temp:-99}" -le 48 ] || suite_skip "the CPU is warm (${start_temp}C): the fan is left alone for two minutes, so run this on an idle laptop (<= 48C)"

orig=$("$CLI" current)
restore() {
  S systemctl reset-failed thinkfan >/dev/null 2>&1
  S systemctl start thinkfan >/dev/null 2>&1; sleep 2
  case "$orig" in manual) "$CLI" manual "$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1
}
trap restore EXIT

# watch the fan level after thinkfan has gone: seconds until it reads "auto" (firmware control), or "none".
# Gives up early if the CPU gets warm (the fan is being left alone).
watch_auto() { # <max seconds>
  local start=$SECONDS
  held=$(fan_level); firmware_after=none
  while [ $((SECONDS - start)) -lt "$1" ]; do
    [ "$(fan_level)" = auto ] && { firmware_after=$((SECONDS - start)); return 0; }
    [ "$(cpu_temp)" -ge 60 ] && { firmware_after="aborted at $(cpu_temp)C"; return 1; }
    sleep 1
  done
  return 1
}

echo "-- a clean stop (what 'systemctl disable --now thinkfan' does): the fan goes back to the firmware"
"$CLI" manual 0; sleep 3
t "before: thinkfan holds the fan at level 0" "$(fan_level)" 0
S systemctl stop thinkfan; sleep 1
t "thinkfan is stopped" "$(systemctl is-active thinkfan)" inactive
echo "   (waiting for the fan watchdog, up to 150 s)"
watch_auto 150
t "after a clean stop the fan returns to automatic (firmware) control within 150 s (took ${firmware_after}s)" "$([ "$firmware_after" != none ] && [[ $firmware_after =~ ^[0-9]+$ ]] && echo yes || echo "no ($firmware_after)")" yes
info "took ${firmware_after}s: the fan may keep its last level until the ThinkPad's 120 s fan watchdog fires (it varies between 0 and ~125 s)"

echo "-- starting again takes the fan back"
S systemctl start thinkfan; sleep 3
t "thinkfan is running again" "$(systemctl is-active thinkfan)" active
"$CLI" manual 0; sleep 3
t "thinkfan holds the fan again (level 0)" "$(fan_level)" 0
t "the plugin reports it is ready" "$(setup_state)" ready

echo "-- a crash (kill -9): nothing gets to clean up"
S kill -9 "$(pidof thinkfan)"; sleep 3
state=$(systemctl is-active thinkfan); first=$(fan_level)
echo "   (waiting for the fan watchdog, up to 150 s)"
watch_auto 150
t "after a crash the fan still returns to automatic (firmware) control within 150 s (took ${firmware_after}s)" "$([[ $firmware_after =~ ^[0-9]+$ ]] && echo yes || echo "no ($firmware_after)")" yes
[ "$first" = auto ] || gap "for about ${firmware_after}s after a crash the fan stays at its last level ($first) with nobody controlling it; only the laptop's own emergency thermal protection is in charge until the watchdog fires"
[ "$state" = active ] && ok "systemd restarted thinkfan on its own" || gap "after a crash thinkfan stays '$state': thinkfan.service has no Restart= policy, so the curves stay off (the panel shows 'Enable fan control') until 'sudo systemctl start thinkfan'"
S systemctl reset-failed thinkfan >/dev/null 2>&1; S systemctl start thinkfan; sleep 3
t "a plain 'systemctl start thinkfan' recovers it" "$(systemctl is-active thinkfan)" active
"$CLI" manual 0; sleep 3
t "and the fan is under thinkfan's control again (level 0, not automatic)" "$(fan_level)" 0

t "the CPU stayed cool throughout (under 60C; started at ${start_temp}C)" "$([ "$(cpu_temp)" -lt 60 ] && echo yes || echo "no ($(cpu_temp))")" yes

finish
