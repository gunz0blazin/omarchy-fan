#!/bin/bash
# Tier: hardware (loads the CPU). A pinned manual level ignores temperature, so a pinned "off" could cook the CPU under load.
# The helper therefore adds a safety row: at 85 C the fan goes to full speed, and back to the pinned level below 80 C.
# Part 1 checks the config the helper writes for every manual level. Part 2 proves it on the real fan: pin "off", load 2 CPU
# threads, and watch the fan stay off while the CPU is cool, jump to full speed at 85 C, and drop back after the load ends.
# Needs an idle, cool laptop (<= 50 C) and about 6 minutes. A hard stop at STOP_C (the hotter of the ThinkPad sensor and the
# CPU's own cores) kills the load and forces full speed; it restores your profile afterwards, also if interrupted.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
[ -n "$1" ] && CLI=$1
STOP_C=${STOP_C:-97}; LOAD=${LOAD:-2}
is_thinkpad || suite_skip "not a ThinkPad"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
command -v yes >/dev/null || suite_skip "needs 'yes' to load the CPU"
start=$(cpu_temp)
[ "${start:-99}" -le 50 ] || suite_skip "the CPU is warm (${start}C): run this on a cool laptop (<= 50C)"

core_max() { local m=0 v f; for f in /sys/class/hwmon/hwmon*/temp*_input; do
  [ "$(cat "$(dirname "$f")/name" 2>/dev/null)" = coretemp ] || continue
  v=$(( $(cat "$f") / 1000 )); [ "$v" -gt "$m" ] && m=$v; done; echo "$m"; }
hot() { local a b; a=$(cpu_temp); b=$(core_max); [ "$a" -gt "$b" ] && echo "$a" || echo "$b"; }
is_full() { local l r; l=$(fan_level); r=$(fan_rpm); { [ "$l" = disengaged ] || [ "$l" = 7 ]; } && [ -n "$r" ] && [ "$r" -ge 4300 ]; }

orig=$("$CLI" current); manual=$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)
nofollow=$([ -e ~/.config/omarchy/fan/no-follow ] && echo yes || echo no)
pids=()
stop_load() { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; pids=(); }
restore() {
  trap - EXIT; stop_load
  "$CLI" balanced >/dev/null 2>&1     # never put a pinned low level back on a hot CPU: cool down on the curve first
  local n=0; while [ "$(hot)" -gt 55 ] && [ $n -lt 80 ]; do sleep 3; n=$((n+1)); done
  if [ "$nofollow" = yes ]; then "$CLI" follow off >/dev/null 2>&1; else "$CLI" follow on >/dev/null 2>&1; fi
  case "$orig" in manual) "$CLI" manual "$manual" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1
}
trap restore EXIT
"$CLI" follow off >/dev/null 2>&1    # a power-profile change must not move the fan during the test

echo "-- the config the helper writes for each manual level"
for n in 0 1 3 7; do
  "$CLI" manual $n >/dev/null; sleep 2
  y=$(cat /etc/thinkfan.yaml)
  t "manual $n: pinned row $n goes up to 85 C" "$(grep -c "^  - \[$n, 0, 85\]" <<<"$y")" 1
  t "manual $n: safety row goes to full speed at 80 C and up" "$(grep -c '^  - \["level full-speed", 80, 32767\]' <<<"$y")" 1
  t "manual $n: thinkfan accepts the config" "$(systemctl is-active thinkfan)" active
done
"$CLI" manual 8 >/dev/null; sleep 2
y=$(cat /etc/thinkfan.yaml)
t "manual 8 (full speed) is a single full-speed row" "$(grep -c '^  - \[' <<<"$y")" 1
t "manual 8: thinkfan accepts the config" "$(systemctl is-active thinkfan)" active

echo "-- live: pin the fan OFF, load $LOAD CPU threads, stop at ${STOP_C}C"
"$CLI" manual 0 >/dev/null; sleep 4
t "fan is pinned off before the load" "$(fan_level)" 0
for i in $(seq 1 "$LOAD"); do yes > /dev/null & pids+=($!); done
t0=$SECONDS; engaged=""; smax=0; max=0; off_while_cool=1; first_cool_off=""; aborted=0
while [ $((SECONDS - t0)) -lt 300 ]; do
  h=$(hot); s=$(cpu_temp); [ "$h" -gt "$max" ] && max=$h; [ "$s" -gt "$smax" ] && smax=$s
  if [ "$h" -ge "$STOP_C" ]; then stop_load; echo "level disengaged" | sudo -n tee /proc/acpi/ibm/fan >/dev/null 2>&1; aborted=1; break; fi
  # while the sensor thinkfan reads is below the cap, the fan must stay pinned off
  if [ "$s" -lt 83 ] && [ "$(fan_level)" != 0 ]; then off_while_cool=0; fi
  if [ -z "$engaged" ] && [ "$smax" -ge 86 ] && is_full; then engaged=$((SECONDS - t0)); echo "   safety engaged at t=${engaged}s: sensor peaked ${smax}C, now ${s}C, level $(fan_level), $(fan_rpm) RPM"; break; fi
  [ $(((SECONDS - t0) % 20)) -lt 2 ] && printf '   t=%3ss  sensor %sC  hottest core %sC  level=%s  rpm=%s\n' $((SECONDS - t0)) "$s" "$(core_max)" "$(fan_level)" "$(fan_rpm)"
  sleep 2
done
t "the fan stayed pinned off while the CPU was below the cap" "$off_while_cool" 1
t "the CPU never reached the ${STOP_C}C hard stop" "$aborted" 0
t "the safety row engaged: full speed once the sensor passed 85 C" "$([ -n "$engaged" ] && echo yes || echo no)" yes
if [ -n "$engaged" ]; then
  # keep the load on a little longer: the fan must hold the CPU, not just spin up once
  hold=$((SECONDS + 40)); hmax=$(hot)
  while [ $SECONDS -lt $hold ]; do h=$(hot); [ "$h" -gt "$hmax" ] && hmax=$h; [ "$h" -ge "$STOP_C" ] && { stop_load; echo "level disengaged" | sudo -n tee /proc/acpi/ibm/fan >/dev/null 2>&1; aborted=1; break; }; sleep 2; done
  info "40 s after engaging, with the load still on: hottest reading ${hmax}C, fan $(fan_rpm) RPM"
  t "the CPU stayed under the ${STOP_C}C hard stop while the safety row held the fan" "$aborted" 0
  t "the fan is still at full speed under the load" "$(is_full && echo yes || echo no)" yes
fi
stop_load
echo "-- load stopped: the fan must drop back to the pinned level (off) once the CPU is below 80 C"
back=""; t1=$SECONDS
while [ $((SECONDS - t1)) -lt 300 ]; do
  [ "$(fan_level)" = 0 ] && [ "$(cpu_temp)" -lt 80 ] && { back=$((SECONDS - t1)); break; }
  sleep 3
done
t "after the load ended the fan went back to the pinned level 0" "$([ -n "$back" ] && echo yes || echo no)" yes
[ -n "$back" ] && info "back to level 0 after ${back}s at $(cpu_temp)C"
t "the hottest reading in the whole test stayed under the ${STOP_C}C stop (peak ${max}C)" "$([ "$max" -lt "$STOP_C" ] && echo yes || echo no)" yes

finish
