#!/bin/bash
# Needs a ThinkPad with the helper installed. Optional $1: path to bin/omarchyfan.
B=${1:-$(dirname "$(readlink -f "$0")")/../bin/omarchyfan}
H=/usr/lib/omarchy-fan/helper
pass=0; failn=0
t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (got '$2', want '$3')"; failn=$((failn+1)); fi; }
orig=$($B current)

for p in quiet balanced performance; do
  $B $p; sleep 1
  t "profile $p" "$($B current)" "$p"
  t "$p config installed" "$(head -1 /etc/thinkfan.yaml | awk '{print $4}')" "$p"
  t "thinkfan active after $p" "$(systemctl is-active thinkfan)" active
done
for n in 0 4 8; do
  $B manual $n; sleep 2
  want=$n; [ $n = 8 ] && want=disengaged
  t "manual $n kernel level" "$(awk '/^level/{print $2}' /proc/acpi/ibm/fan)" "$want"
done
echo "-- rapid manual changes (restart-limit regression)"
for n in 1 2 3 4 5 6 7 8 0; do $B manual $n >/dev/null; done; sleep 2
t "thinkfan survives 9 rapid restarts" "$(systemctl is-active thinkfan)" active
t "last rapid change applied" "$(awk '/^level/{print $2}' /proc/acpi/ibm/fan)" 0

echo "-- helper rejects bad input"
for args in "set manual 9" "set manual -1" "set manual 1;id" "set manual" "set ../../etc/passwd" "set quiet/../x" "set" "bogus" ""; do
  pkexec $H $args >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && { echo "  PASS  rejected: '$args'"; pass=$((pass+1)); } || { echo "  FAIL  accepted: '$args'"; failn=$((failn+1)); }
done
t "config untouched by bad input" "$(head -1 /etc/thinkfan.yaml | awk '{print $4}')" manual
t "no stray .new file" "$(ls /etc/thinkfan.yaml.new 2>/dev/null | wc -l)" 0

# restore
case "$orig" in manual) $B manual "$(cat ~/.config/omarchy/fan/manual-level)" ;; *) $B "$orig" ;; esac
echo "restored: $($B current)"
echo "$pass passed, $failn failed"
[ $failn = 0 ]
