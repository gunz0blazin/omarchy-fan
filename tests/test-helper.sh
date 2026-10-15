#!/bin/bash
# Tier: hardware. Needs a ThinkPad with the root helper installed. Changes your fan profile while it runs and puts it
# back at the end (also if interrupted). Optional $1: path to the command (default: the one in this checkout).
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$1" ] && CLI=$1
is_thinkpad || suite_skip "not a ThinkPad"
H=/usr/lib/omarchy-fan/helper
[ -x "$H" ] || suite_skip "the root helper is not installed"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"

orig=$("$CLI" current)
restore() { case "$orig" in manual) "$CLI" manual "$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1; }
trap restore EXIT

echo "-- each curve applies (thinkfan gets that curve)"
for p in quiet balanced performance; do
  "$CLI" "$p"; sleep 1
  t "$p curve is the active thinkfan config" "$(head -1 /etc/thinkfan.yaml | awk '{print $4}')" "$p"
done
t "thinkfan is running after the last switch" "$(systemctl is-active thinkfan)" active

echo "-- manual levels reach the kernel"
for n in 0 4 8; do
  "$CLI" manual $n; sleep 2
  want=$n; [ $n = 8 ] && want=disengaged        # full speed is reported as "disengaged"
  t "manual $n kernel level" "$(fan_level)" "$want"
done

echo "-- rapid manual changes (restart-limit regression: thinkfan must not be refused a restart)"
for n in 1 2 3 4 5 6 7 8 0; do "$CLI" manual $n >/dev/null; done; sleep 2
t "thinkfan survives 9 rapid restarts" "$(systemctl is-active thinkfan)" active
t "the last rapid change was applied" "$(fan_level)" 0

echo "-- the root helper rejects bad input (and changes nothing)"
"$CLI" manual 2 >/dev/null; sleep 1
before=$(md5sum < /etc/thinkfan.yaml)
for args in "set manual 9" "set manual -1" "set manual 1;id" "set manual" "set ../../etc/passwd" "set quiet/../x" "set" "bogus" ""; do
  pkexec "$H" $args >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && ok "rejected: '$args'" || bad "ACCEPTED: '$args'"
done
t "thinkfan config is byte-for-byte unchanged by bad input" "$(md5sum < /etc/thinkfan.yaml)" "$before"
t "no stray .new file left behind" "$(ls /etc/thinkfan.yaml.new 2>/dev/null | wc -l)" 0

finish
