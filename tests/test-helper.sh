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

echo "-- an outdated helper is noticed (update-available), and reapply puts the profile back through the helper"
t "the installed helper is current: setup is ready" "$("$CLI" stats | awk -F'\t' '$1=="setup"{print $2}')" ready
t "a simulated older helper: setup is update-available" "$(OMARCHYFAN_HELPER_VERSION=0.0.1-1 "$CLI" stats | awk -F'\t' '$1=="setup"{print $2}')" update-available
t "a simulated newer helper: setup is ready" "$(OMARCHYFAN_HELPER_VERSION=99.0-1 "$CLI" stats | awk -F'\t' '$1=="setup"{print $2}')" ready
"$CLI" quiet >/dev/null; sleep 1
# plant a stale line first, so a reapply that does nothing cannot pass
if echo "# stale curve, as left behind by an older helper" | sudo -n tee -a /etc/thinkfan.yaml >/dev/null 2>&1; then
  t "the stale line is in the config (setup for the next check)" "$(cmp -s /etc/thinkfan.yaml /usr/share/omarchy-fan/profiles/quiet.yaml && echo same || echo differs)" differs
  "$CLI" reapply >/dev/null 2>&1; sleep 2
  t "reapply puts the active profile back through the helper (the config is the installed quiet curve again)" "$(cmp -s /etc/thinkfan.yaml /usr/share/omarchy-fan/profiles/quiet.yaml && echo yes || echo no)" yes
else
  skip "reapply rewrites a stale config (needs passwordless sudo to plant the stale line)"
fi
t "reapply leaves the active profile as it was" "$("$CLI" current)" quiet
"$CLI" manual 3 >/dev/null; sleep 1; "$CLI" reapply >/dev/null 2>&1; sleep 2
t "reapply keeps a pinned manual level (level 3)" "$(fan_level)" 3
t "reapply keeps the profile 'manual'" "$("$CLI" current)" manual

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
