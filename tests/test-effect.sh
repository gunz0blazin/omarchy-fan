#!/bin/bash
# Tier: hardware. Checks the fan really changes speed when asked: the other tests only look at the level that was
# REQUESTED (/proc/acpi/ibm/fan "level"), which would also pass if the fan ignored it. Needs a ThinkPad with the helper
# set up and a cool CPU. Takes about a minute and the fan gets loud for a few seconds. Restores your profile (also if
# interrupted). Aborts and puts the fan on Performance if the CPU reaches 80C. Optional $1: path to the command.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$1" ] && CLI=$1
is_thinkpad || suite_skip "not a ThinkPad"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
start_temp=$(cpu_temp)
[ "${start_temp:-99}" -le 65 ] || suite_skip "the CPU is warm (${start_temp}C): the fan-off step needs an idle laptop (<= 65C)"

orig=$("$CLI" current)
restore() { case "$orig" in manual) "$CLI" manual "$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1; }
trap restore EXIT

# wait up to $3 seconds until the RPM satisfies "$1 $2"; prints the seconds it took, or "none"
reached=""
wait_rpm() { # <min|max|range> <rpm, or "lo hi" for range> <timeout>
  local start=$SECONDS r
  while [ $((SECONDS - start)) -lt "$3" ]; do
    r=$(fan_rpm); [ "$(cpu_temp)" -ge 80 ] && { "$CLI" performance >/dev/null 2>&1; reached=hot; return 1; }
    if [ -n "$r" ]; then
      if [ "$1" = min ] && [ "$r" -ge "$2" ]; then reached=$((SECONDS - start)); return 0; fi
      if [ "$1" = max ] && [ "$r" -le "$2" ]; then reached=$((SECONDS - start)); return 0; fi
      if [ "$1" = range ]; then
        read -r lo hi <<<"$2"
        if [ "$r" -ge "$lo" ] && [ "$r" -le "$hi" ]; then reached=$((SECONDS - start)); return 0; fi
      fi
    fi
    sleep 0.5
  done
  reached=none; return 1
}
settle_rpm() { sleep "$1"; fan_rpm; }

echo "-- the fan speeds up"
"$CLI" manual 8
wait_rpm min 5000 30 && ok "full speed (8): the fan reaches 5000+ RPM in ${reached}s" || bad "full speed (8): the fan did not reach 5000 RPM within 30s (reached: $reached)"
full=$(settle_rpm 4)
t "full speed settles at 5500 RPM or more" "$([ "${full:-0}" -ge 5500 ] && echo yes || echo "no ($full)")" yes

echo "-- it slows to a middle level"
"$CLI" manual 4
wait_rpm range "3000 5200" 40 && ok "level 4: the fan settles into 3000-5200 RPM in ${reached}s" || bad "level 4: the fan did not settle into 3000-5200 RPM within 40s (reached: $reached)"
mid=$(settle_rpm 5)
t "and stays there (still 3000-5200 RPM five seconds later)" "$([ "${mid:-0}" -ge 3000 ] && [ "${mid:-0}" -le 5200 ] && echo yes || echo "no ($mid)")" yes

echo "-- and it stops"
"$CLI" manual 0
wait_rpm max 2500 60 && ok "off (0): the fan drops below 2500 RPM in ${reached}s" || bad "off (0): the fan was still above 2500 RPM after 60s (reached: $reached)"
low=$(settle_rpm 8)
t "the fan is far slower than at level 4 (less than half)" "$([ "${low:-99999}" -lt $((mid/2)) ] && echo yes || echo "no (level 4: $mid, now: $low)")" yes

echo "-- ordering"
t "RPM ordering: full speed > level 4 > off" "$([ "${full:-0}" -gt "${mid:-0}" ] && [ "${mid:-0}" -gt "${low:-0}" ] && echo yes || echo "no ($full / $mid / $low)")" yes
t "the CPU stayed cool during the test (under 80C; started at ${start_temp}C)" "$([ "$(cpu_temp)" -lt 80 ] && echo yes || echo "no ($(cpu_temp))")" yes

finish
