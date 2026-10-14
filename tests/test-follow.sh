#!/bin/bash
# Needs the plugin running in the bar (it starts the follower) and the helper installed; restores power profile, fan profile and follow flag
B=${1:-$(dirname "$(readlink -f "$0")")/../bin/omarchyfan}
pass=0; failn=0
t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (got '$2', want '$3')"; failn=$((failn+1)); fi; }
orig_pp=$(powerprofilesctl get); orig_fan=$($B current)
t "follower running" "$(pgrep -f '^/usr/bin/bash [^ ]*/bin/omarchy-fan-follow$' | wc -l)" 1

$B follow on; $B balanced; powerprofilesctl set balanced; sleep 2
powerprofilesctl set power-saver; sleep 5
t "follow on: power-saver -> quiet" "$($B current)" quiet
powerprofilesctl set performance; sleep 5
t "follow on: performance -> performance" "$($B current)" performance
$B manual 5; sleep 2
$B follow off
powerprofilesctl set balanced; sleep 5
t "follow off: manual setting kept" "$($B current)" manual
$B follow on
powerprofilesctl set power-saver; sleep 5
t "follow back on: power-saver -> quiet" "$($B current)" quiet

powerprofilesctl set "$orig_pp"; sleep 4
$B "$orig_fan" 2>/dev/null || $B balanced
echo "restored: power=$(powerprofilesctl get) fan=$($B current) follow=$($B stats | awk -F'\t' '$1=="follow"{print $2}')"
echo "$pass passed, $failn failed"
[ $failn = 0 ]
