#!/bin/bash
# Tier: destructive (heats the CPU, reloads the driver, suspends the laptop, and removes then reinstalls the plugin).
# THE SAFETY TEST: what happens when things go wrong on a real ThinkPad. It is the testing done to release this plugin, in parts.
# Run the default four (about 25 minutes, plugged in for the full effect) or pick: PARTS="net reload" bash tests/test-safety.sh
#   net      the manual-mode safety net, config only (about 10 s): every pinned level gets a full-speed row at 80 C and up
#   netlive  the same on the real fan under load (about 6 min): a pinned "fan off" goes to full speed at 85 C and back below 80 C
#   reload   reloading the thinkpad_acpi driver (the boot hook / "Enable fan control") leaves LEDs, battery limits, hotkeys, radios intact
#   suspend  OPT-IN (PARTS=suspend): suspend to RAM and resume (real `systemctl suspend`, RTC wake): thinkfan, the fan level, the follower and the panel recover.
#            Not run by default: Omarchy locks the screen on suspend and you have to unlock it
#   load     a heavy 4-thread load under each profile: the fan must be at full speed before the CPU reaches 90 C
#   rip      run the README Uninstall mid-load and check the fan goes back to the firmware within 10 s (about 2 min incl. reinstall).
#            RIP_HOT=1 makes it the WORST CASE: heat the CPU as hot as fan control allows, soak it 90 s, then remove (about 10 min)
# A kill switch stops every load and forces full fan when ANY thermal zone is within STOP_MARGIN (default 2) C of its own critical
# (kernel power-off) trip, or the CPU is at 99 C: on the T480s the zone B0D4 powers the machine off at 98 C. Everything is restored
# at the end, also if interrupted. Needs: passwordless sudo, an idle laptop, network (only to reinstall after `rip`).
# Known hardware limit: plugged in, a 4-thread load can heat this class of laptop past what the fan can handle; the kill switch ends the
# run, and that is recorded as a known gap, not a failure. On battery the CPU is clock-limited and the load part stays cool.
PARTS=${PARTS:-"net netlive reload load rip"}     # suspend is opt-in only: it locks the screen, so it is not in the default run or in full-test
want() { case " $PARTS " in *" $1 "*) return 0;; esac; return 1; }
# `rip` removes the plugin folder this script would otherwise run from: work from a scratch copy of the repo
if want rip && [ -z "$OMARCHYFAN_SAFETY_COPY" ]; then
  src=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd); copy=$(mktemp -d); cp -a "$src/." "$copy/"
  OMARCHYFAN_SAFETY_COPY=1 exec bash "$copy/tests/test-safety.sh" "$@"
fi
. "$(dirname "$(readlink -f "$0")")/lib.sh"
STOP_MARGIN=${STOP_MARGIN:-2}; LOAD_THREADS=${LOAD_THREADS:-4}; LOAD_SECS=${LOAD_SECS:-120}; RIP_SOAK=${RIP_SOAK:-90}; RIP_WINDOW=${RIP_WINDOW:-60}
PDIR=~/.config/omarchy/plugins/$ID; CLI=$PDIR/bin/omarchyfan
IPC="quickshell ipc -p /usr/share/omarchy/shell call $ID"
TA=/sys/devices/platform/thinkpad_acpi

is_thinkpad || suite_skip "not a ThinkPad"
[ -d "$PDIR" ] && [ -x "$CLI" ] || suite_skip "the plugin is not installed (this test uses the installed plugin)"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
sudo -n true 2>/dev/null || suite_skip "needs passwordless sudo"
command -v yes >/dev/null || suite_skip "needs 'yes' to load the CPU"
[ "$(pgrep -cx steam)$(pgrep -cx dota2)" = 00 ] || suite_skip "a game is running on this laptop"

# ---------- sensors ----------
core_max() { local m=0 v f; for f in /sys/class/hwmon/hwmon*/temp*_input; do [ "$(cat "$(dirname "$f")/name" 2>/dev/null)" = coretemp ] || continue
  v=$(( $(cat "$f") / 1000 )); [ "$v" -gt "$m" ] && m=$v; done; echo "$m"; }
hot() { local a b; a=$(cpu_temp); b=$(core_max); [ "$a" -gt "$b" ] && echo "$a" || echo "$b"; }
# degrees left before the nearest power-off trip: any thermal zone's critical trip (up to 110 C), or the CPU's own 100 C
margin() { local m=$((100 - $(core_max))) z tp c t d
  for z in /sys/class/thermal/thermal_zone*; do for tp in "$z"/trip_point_*_type; do
    [ "$(cat "$tp" 2>/dev/null)" = critical ] || continue
    c=$(( $(cat "${tp%_type}_temp" 2>/dev/null || echo 0) / 1000 )); { [ "$c" -gt 0 ] && [ "$c" -le 110 ]; } || continue
    t=$(( $(cat "$z/temp" 2>/dev/null || echo 0) / 1000 )); d=$((c - t)); [ "$d" -lt "$m" ] && m=$d; done; done; echo "$m"; }
zone_hot() { local best=0 z t; for z in /sys/class/thermal/thermal_zone*; do t=$(( $(cat "$z/temp" 2>/dev/null || echo 0) / 1000 )); [ "$t" -gt "$best" ] && [ "$t" -lt 128 ] && best=$t; done; echo "$best"; }
freq() { awk -F: '/cpu MHz/{s+=$2;n++} END{printf "%d", s/n}' /proc/cpuinfo; }
is_full() { local l r; l=$(fan_level); r=$(fan_rpm); { [ "$l" = disengaged ] || [ "$l" = 7 ]; } && [ -n "$r" ] && [ "$r" -ge 4300 ]; }

# ---------- load, kill switch, state ----------
pids=(); tripped=0
stop_load()  { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; pids=(); pkill -x yes 2>/dev/null; }
start_load() { local i; for i in $(seq 1 "$1"); do yes > /dev/null & pids+=($!); done; }
full_fan()   { echo "level disengaged" | sudo -n tee /proc/acpi/ibm/fan >/dev/null 2>&1; }
guard() { if [ "$(margin)" -le "$STOP_MARGIN" ] || [ "$(core_max)" -ge 99 ]; then stop_load; full_fan; tripped=1; return 1; fi; return 0; }

orig=$("$CLI" current); manual=$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 0)
nofollow=$([ -e ~/.config/omarchy/fan/no-follow ] && echo yes || echo no); orig_pp=$(powerprofilesctl get 2>/dev/null)
origin_url=$(git -C "$PDIR" remote get-url origin 2>/dev/null); branch0=$(git -C "$PDIR" branch --show-current 2>/dev/null)
index=$(jq -r --arg id "$ID" '[.. | objects | select(has("right")) | .right | map(.id)][0] | index($id) // empty' ~/.config/omarchy/shell.json 2>/dev/null)
restore() {
  trap - EXIT; stop_load
  if [ ! -d "$PDIR" ] && [ -e "$ROOT/.git" ]; then omarchy plugin add "file://$ROOT" --enable --yes >/dev/null 2>&1; fi
  if [ -d "$PDIR" ] && { ! pacman -Q omarchy-fan-helper >/dev/null 2>&1 || ! command -v thinkfan >/dev/null; }; then ( cd "$PDIR" && yes | bash install-helper.sh >/dev/null 2>&1 ); fi
  sudo -n systemctl reset-failed thinkfan >/dev/null 2>&1; sudo -n systemctl start thinkfan >/dev/null 2>&1; sleep 2
  "$CLI" manual 8 >/dev/null 2>&1     # never put a pinned low level back on a hot CPU: cool at max fan first
  local n=0; while [ "$(cpu_temp)" -gt 52 ] && [ $n -lt 100 ]; do sleep 3; n=$((n+1)); done
  if [ -n "$origin_url" ] && [ -n "$branch0" ] && [ -d "$PDIR" ]; then
    git -C "$PDIR" remote set-url origin "$origin_url" 2>/dev/null; git -C "$PDIR" fetch -q origin 2>/dev/null
    git -C "$PDIR" checkout -q -B "$branch0" "origin/$branch0" 2>/dev/null; git -C "$PDIR" branch -u "origin/$branch0" >/dev/null 2>&1; fi
  [ -n "$index" ] && omarchy bar move "$ID" --section right --index "$index" >/dev/null 2>&1
  [ -n "$orig_pp" ] && powerprofilesctl set "$orig_pp" >/dev/null 2>&1
  if [ "$nofollow" = yes ]; then "$CLI" follow off >/dev/null 2>&1; else "$CLI" follow on >/dev/null 2>&1; fi
  case "$orig" in manual) "$CLI" manual "$manual" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1
  echo "   restored: plugin $(plugin_state), setup $("$CLI" stats 2>/dev/null | awk -F'\t' '$1=="setup"{print $2}'), profile $("$CLI" current 2>/dev/null), thinkfan $(systemctl is-active thinkfan), CPU $(cpu_temp)C"
  [ "$OMARCHYFAN_SAFETY_COPY" = 1 ] && rm -rf "${ROOT:?}"
}
trap restore EXIT
"$CLI" follow off >/dev/null 2>&1    # a power-profile change must not move the fan during the test

cool() {   # fan at max until the ThinkPad sensor is below 50 C for 20 s straight (it is the reading the plugin uses)
  "$CLI" manual 8 >/dev/null 2>&1; local c0=$SECONDS h
  while [ "$(cpu_temp)" -ge 50 ] && [ $((SECONDS - c0)) -lt 300 ]; do sleep 2; done
  h=$SECONDS; while [ $((SECONDS - h)) -lt 20 ] && [ $((SECONDS - c0)) -lt 420 ]; do [ "$(cpu_temp)" -ge 50 ] && h=$SECONDS; sleep 2; done
  info "cooled in $((SECONDS - c0))s: sensor $(cpu_temp)C, hottest core $(core_max)C"
}
echo "setup: AC=$(cat /sys/class/power_supply/AC/online) (1 = plugged in), CPU $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | cut -c1-34), $(nproc) threads, nearest power-off trip $(margin)C away, parts: $PARTS"
[ "$(cat /sys/class/power_supply/AC/online)" = 1 ] || info "on battery: the CPU is clock-limited, so the heat parts (load, rip) stay cool and prove less; plug in for the full test"

# ====================================================================================================== net
if want net; then
  echo; echo "== net: manual-mode safety net"
  for n in 0 1 3 7; do
    "$CLI" manual $n >/dev/null; sleep 2; y=$(cat /etc/thinkfan.yaml)
    t "manual $n: the pinned row goes up to 85 C" "$(grep -c "^  - \[$n, 0, 85\]" <<<"$y")" 1
    t "manual $n: the safety row goes to full speed at 80 C and up" "$(grep -c '^  - \["level full-speed", 80, 32767\]' <<<"$y")" 1
    t "manual $n: thinkfan accepts the config" "$(systemctl is-active thinkfan)" active
  done
  "$CLI" manual 8 >/dev/null; sleep 2
  t "manual 8 (full speed) is a single full-speed row" "$(grep -c '^  - \[' /etc/thinkfan.yaml)" 1
fi
if want netlive; then
  echo; echo "== netlive: the manual-mode safety net on the real fan under load"
  cool; "$CLI" manual 0 >/dev/null; sleep 4
  t "live: the fan is pinned off before the load" "$(fan_level)" 0
  start_load 2; t0=$SECONDS; engaged=""; smax=0; off_ok=1; pk=0
  while [ $((SECONDS - t0)) -lt 300 ]; do
    guard || break
    h=$(hot); s=$(cpu_temp); [ "$h" -gt "$pk" ] && pk=$h; [ "$s" -gt "$smax" ] && smax=$s
    [ "$s" -lt 83 ] && [ "$(fan_level)" != 0 ] && off_ok=0
    [ -z "$engaged" ] && [ "$smax" -ge 86 ] && is_full && { engaged=$((SECONDS - t0)); break; }
    sleep 2
  done
  t "live: the fan stayed pinned off while the CPU was below the cap" "$off_ok" 1
  t "live: the safety row engaged: full speed once the sensor passed 85 C ($([ -n "$engaged" ] && echo "at ${engaged}s, sensor peak ${smax}C"))" "$([ -n "$engaged" ] && echo yes || echo no)" yes
  hold=$((SECONDS + 40)); while [ $SECONDS -lt $hold ] && [ $tripped = 0 ]; do guard || break; sleep 2; done
  [ $tripped = 1 ] && gap "net: even at full fan this load reached $(margin)C from the power-off trip: the safety stop ended it (hardware limit, see the header)" || ok "live: with the load still on, full fan held the CPU clear of the power-off trip for 40 s more"
  stop_load; tripped=0
  b=""; t1=$SECONDS; while [ $((SECONDS - t1)) -lt 300 ]; do [ "$(fan_level)" = 0 ] && [ "$(cpu_temp)" -lt 80 ] && { b=$((SECONDS - t1)); break; }; sleep 3; done
  t "live: after the load ended the fan dropped back to the pinned level 0 ($([ -n "$b" ] && echo "${b}s, $(cpu_temp)C"))" "$([ -n "$b" ] && echo yes || echo no)" yes
fi

# ====================================================================================================== reload
if want reload; then
  echo; echo "== reload: the thinkpad_acpi driver reload (boot hook / 'Enable fan control')"
  snap() {
    echo "module=$(lsmod | awk '$1=="thinkpad_acpi"{print "loaded"}')"; echo "fan_control=$(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null)"
    for f in /sys/class/power_supply/BAT0/charge_control_start_threshold /sys/class/power_supply/BAT0/charge_control_end_threshold; do [ -r "$f" ] && echo "$(basename "$f")=$(cat "$f")"; done
    for l in /sys/class/leds/platform::mute /sys/class/leds/platform::micmute /sys/class/leds/tpacpi::kbd_backlight /sys/class/leds/tpacpi::thinklight; do [ -e "$l" ] && echo "led $(basename "$l")=$(cat "$l/brightness")"; done
    echo "leds=$(ls /sys/class/leds | grep -E 'tpacpi|platform::' | sort | tr '\n' ' ')"; echo "proc_ibm=$(ls /proc/acpi/ibm 2>/dev/null | tr '\n' ' ')"
    echo "input=$(grep -E '^N: Name=.*(ThinkPad|TPPS|TrackPoint)' /proc/bus/input/devices | sort | tr '\n' ' ')"
    # (the deprecated attributes hotkey_enable / bluetooth_enable are not read: reading them makes the kernel log a warning)
    for a in hotkey_mask hotkey_all_mask hotkey_recommended_mask hotkey_poll_freq wwan_enable; do [ -r "$TA/$a" ] && echo "attr $a=$(cat "$TA/$a" 2>/dev/null | tr '\n' ' ')"; done
    # one line per radio, so the order they are listed in (it changes when the driver re-registers its switch) does not matter
    rfkill list 2>/dev/null | awk '/^[0-9]+:/{n=$2" "$3} /Soft blocked/{print "rfkill " n " soft=" $3}'
    echo "bluetooth_powered=$(bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2}')"
  }
  B=$(mktemp); snap | sort > "$B"
  sudo -n dmesg -C >/dev/null 2>&1 || true
  for round in 1 2; do
    sudo -n systemctl stop thinkfan; sleep 1
    sudo -n modprobe -r thinkpad_acpi; r1=$?; sudo -n modprobe thinkpad_acpi fan_control=1; r2=$?; sleep 3
    sudo -n systemctl start thinkfan; sleep 3
    t "round $round: the driver unloads and loads again cleanly" "$r1$r2" 00
    t "round $round: fan_control is back on and thinkfan runs" "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)/$(systemctl is-active thinkfan)" Y/active
    d=$(snap | sort | diff "$B" -); if [ -z "$d" ]; then ok "round $round: LEDs, battery limits, hotkeys, input devices, Wi-Fi and Bluetooth are identical to before"; else bad "round $round: these changed: $(echo "$d" | tr '\n' ' ' | cut -c1-200)"; fi
    "$CLI" manual 2 >/dev/null; sleep 4; t "round $round: the fan answers a command afterwards" "$(fan_level)" 2
  done
  echo "   (boot path: the driver loaded WITHOUT fan_control, as the initramfs does)"
  sudo -n systemctl stop thinkfan; sleep 1; sudo -n modprobe -r thinkpad_acpi; sudo -n modprobe thinkpad_acpi fan_control=0; sleep 2
  t "after an initramfs-style load fan control is off (the problem the fix is for)" "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)" N
  sudo -n systemctl reset-failed thinkfan 2>/dev/null; sudo -n systemctl start thinkfan 2>/dev/null; sleep 3
  t "thinkfan starts anyway: the service's own boot hook turned fan control back on" "$(systemctl is-active thinkfan)/$(cat /sys/module/thinkpad_acpi/parameters/fan_control)" active/Y
  d=$(snap | sort | diff "$B" -); if [ -z "$d" ]; then ok "boot path: everything the driver provides is identical to before"; else bad "boot path: these changed: $(echo "$d" | tr '\n' ' ' | cut -c1-200)"; fi
  w=$(sudo -n dmesg 2>/dev/null | grep -iE 'thinkpad' | grep -iE 'err|fail|unable|bug|oops' | head -3)
  t "the kernel logged no thinkpad_acpi errors during all of this" "${w:-none}" none
  rm -f "$B"
fi

# ====================================================================================================== suspend
if want suspend; then
  echo; echo "== suspend: suspend to RAM (RTC wake after 40 s) and resume"
  if ! grep -q mem /sys/power/state || [ ! -e /sys/class/rtc/rtc0/wakealarm ] || [ -n "$SKIP_SUSPEND" ]; then info "suspend skipped (no suspend-to-RAM, no RTC wake alarm, or SKIP_SUSPEND set)"
  else
    suspend_cycle() {
      local name=$1 f0 p0 t0 rc e j
      sudo -n journalctl -k --no-pager >/dev/null 2>&1
      p0=$("$CLI" current); t0=$(date +%s)
      sync; sudo -n rtcwake -m no -s 40 >/dev/null 2>&1 && sudo -n systemctl suspend >/dev/null 2>&1; rc=$?
      sleep 25    # the suspend takes effect during this sleep (the script is frozen, then continues after the wake)
      t "$name: the machine really suspended (kernel logged 'suspend entry')" "$(sudo -n journalctl -k --since "@$t0" --no-pager 2>/dev/null | grep -c 'PM: suspend entry' | awk '{print ($1>0)?"yes":"no"}')" yes
      t "$name: the sleep hook (thinkfan-sleep) and wake hook (thinkfan-wakeup) both ran" "$(for u in thinkfan-sleep thinkfan-wakeup; do sudo -n journalctl -u $u --since "@$t0" --no-pager 2>/dev/null | grep -c -E 'Finished'; done | awk '{s+=($1>0)} END{print s}')" 2
      t "$name: thinkfan is running after resume" "$(systemctl is-active thinkfan)" active
      t "$name: the active profile is unchanged" "$("$CLI" current)" "$p0"
      if [ "$p0" = manual ]; then t "$name: the pinned fan level is back" "$(fan_level)" "$(cat ~/.config/omarchy/fan/manual-level)"
      else t "$name: thinkfan is steering the fan again (not left on firmware 'auto')" "$([ "$(fan_level)" != auto ] && echo yes || echo no)" yes; fi
      t "$name: the plugin reports setup ready and reads the temperature" "$(setup_state)/$([ -n "$(cpu_temp)" ] && [ "$(cpu_temp)" -gt 10 ] && echo yes || echo no)" ready/yes
      t "$name: exactly one follower is running" "$(follower_count)" 1
      $IPC open >/dev/null 2>&1; e=$?; sleep 2; $IPC close >/dev/null 2>&1; t "$name: the panel still opens over IPC" "$e" 0
      e=$(qs log -p /usr/share/omarchy/shell --tail 400 2>&1 | grep -iE 'thinkpad|omarchyfan|omarchy-fan' | grep -iE 'error|fail|cannot|unable|not found' | head -2)
      t "$name: no plugin errors in the shell log" "${e:-none}" none
      # thinkfan's own "Going to sleep: Will allow sensor read errors" line is the hook working, not an error
      j=$(sudo -n journalctl -u thinkfan -u thinkfan-sleep -u thinkfan-wakeup --since "@$t0" --no-pager 2>/dev/null | grep -v 'Going to sleep' | grep -iE 'error|fail|cannot|invalid|timeout' | head -2)
      t "$name: no errors from the thinkfan units since the suspend" "${j:-none}" none
    }
    "$CLI" follow off >/dev/null; "$CLI" manual 2 >/dev/null; sleep 4; suspend_cycle "suspend A (pinned level 2)"
    "$CLI" follow on >/dev/null; powerprofilesctl set balanced >/dev/null 2>&1; sleep 2; "$CLI" balanced >/dev/null; sleep 3; suspend_cycle "suspend B (Balanced + follow)"
    powerprofilesctl set power-saver >/dev/null 2>&1; sleep 8; t "after resume the follower still reacts: power-saver gives the Quiet profile" "$("$CLI" current)" quiet
    powerprofilesctl set performance >/dev/null 2>&1; sleep 8; t "after resume the follower still reacts: performance gives the Performance profile" "$("$CLI" current)" performance
  fi
fi

# ====================================================================================================== load
if want load; then
  echo; echo "== load: $LOAD_THREADS busy threads for ${LOAD_SECS}s under each profile (stop within ${STOP_MARGIN}C of a power-off trip)"
  for prof in performance balanced quiet; do
    cool; "$CLI" "$prof" >/dev/null; sleep 4; start_load "$LOAD_THREADS"
    t0=$SECONDS; pk_s=0; pk_c=0; t90=""; tfull=""; tripped=0; minmhz=99999; stop_at=""
    while [ $((SECONDS - t0)) -lt "$LOAD_SECS" ]; do
      s=$(cpu_temp); c=$(core_max); f=$(freq)
      [ "$s" -gt "$pk_s" ] && pk_s=$s; [ "$c" -gt "$pk_c" ] && pk_c=$c; [ "$f" -lt "$minmhz" ] && minmhz=$f
      [ -z "$t90" ] && [ "$s" -ge 90 ] && t90=$((SECONDS - t0))
      [ -z "$tfull" ] && is_full && tfull=$((SECONDS - t0))
      guard || { stop_at=$((SECONDS - t0)); break; }
      sleep 1
    done
    stop_load
    info "$prof: peak sensor ${pk_s}C, hottest core ${pk_c}C; 90C after ${t90:-never}s; fan at full after ${tfull:-never}s; lowest CPU clock ${minmhz} MHz"
    t "$prof: the fan reached full speed by the time the sensor reached 90 C" "$([ -z "$t90" ] || { [ -n "$tfull" ] && [ "$tfull" -le "$t90" ]; } && echo yes || echo no)" yes
    if [ "$tripped" = 1 ]; then gap "$prof: plugged in, this laptop cannot hold a $LOAD_THREADS-thread load with the fan alone: the safety stop ended it at ${stop_at}s (core ${pk_c}C, CPU clock never below ${minmhz} MHz)"
    else ok "$prof: the full ${LOAD_SECS}s completed with the CPU clear of every power-off trip (peak ${pk_s}C)"; fi
    tripped=0
  done
fi

# ====================================================================================================== rip
if want rip; then
  RIP_HOT=${RIP_HOT:-0}
  echo; echo "== rip: run the README Uninstall under load$([ "$RIP_HOT" = 1 ] && echo ", WORST CASE (hot soak ${RIP_SOAK}s)")"
  if [ ! -e "$ROOT/.git" ]; then info "rip skipped: needs a git checkout to reinstall from"
  else
    block=$(awk '/^## Uninstall/{on=1;next} /^## /{on=0} on && /^    [^ ]/{sub(/^    /,""); print}' "$ROOT/README.md")
    script=$(mktemp); echo "$block" | sed -e 's/\bsudo /sudo -n /g' -e 's/pacman -Rns/pacman -Rns --noconfirm/' -e 's#\(omarchy plugin remove [^ ]*\)#\1 --yes#' > "$script"
    go=1
    if [ "$RIP_HOT" = 1 ]; then
      cool
      # thinkfan runs a "bang-bang" curve: fan OFF until the sensor passes 94 C, then FULL SPEED until it is back under 91 C
      sudo -n tee /etc/thinkfan.yaml >/dev/null <<'YAML'
# omarchy-fan profile: test-hot (written by test-safety.sh)
sensors:
  - tpacpi: /proc/acpi/ibm/thermal
    indices: [0]
fans:
  - tpacpi: /proc/acpi/ibm/fan
levels:
  - [0, 0, 94]
  - ["level full-speed", 91, 32767]
YAML
      sudo -n systemctl restart thinkfan; sleep 3
      start_load 2; t0=$SECONDS; tripped=0; reached=0
      while [ $((SECONDS - t0)) -lt 420 ]; do guard || break; [ "$(hot)" -ge 94 ] && { reached=1; break; }; sleep 2; done
      if [ $reached = 0 ]; then stop_load; go=0; gap "rip: the CPU did not reach 94C hot (on battery or well cooled), or the safety stop ended the heat-up: the plugin was not removed"
      else
        info "reached 94C hottest after $((SECONDS - t0))s: soaking ${RIP_SOAK}s"; ss=$SECONDS; lo=999; hi=0
        while [ $((SECONDS - ss)) -lt "$RIP_SOAK" ]; do guard || break; h=$(hot); [ "$h" -lt "$lo" ] && lo=$h; [ "$h" -gt "$hi" ] && hi=$h; sleep 2; done
        if [ $tripped = 1 ]; then stop_load; go=0; gap "rip: the safety stop ended the soak: the plugin was not removed"; else ok "rip: held ${lo}-${hi}C for ${RIP_SOAK}s with the fan off/full bang-bang"; fi
      fi
    else
      # fast version: the plugin keeps control of the fan (Balanced) while 2 threads load the CPU for 25 s, then it is removed
      "$CLI" balanced >/dev/null; sleep 3; start_load 2; t0=$SECONDS; tripped=0
      while [ $((SECONDS - t0)) -lt 25 ]; do guard || break; sleep 1; done
      [ $tripped = 1 ] && { go=0; stop_load; gap "rip: the safety stop ended the warm-up: the plugin was not removed"; }
    fi
    if [ $go = 1 ]; then
      pre=$(hot); echo "   removing the plugin at ${pre}C hottest (sensor $(cpu_temp)C, fan level $(fan_level)), load still on"; sync
      tu=$SECONDS; ( bash "$script" > /dev/null 2>&1; echo $? > "$script.rc" ) & ub=$!
      mx=$pre; stopped=""; auto=""; window=$([ "$RIP_HOT" = 1 ] && echo "$RIP_WINDOW" || echo 15); end=$((SECONDS + window))
      while [ $SECONDS -lt "$end" ]; do
        guard || break; h=$(hot); [ "$h" -gt "$mx" ] && mx=$h
        [ -z "$stopped" ] && [ "$(systemctl is-active thinkfan)" != active ] && stopped=$((SECONDS - tu))
        [ -z "$auto" ] && [ "$(fan_level)" = auto ] && auto=$((SECONDS - tu))
        sleep 1
      done
      stop_load; wait $ub 2>/dev/null
      t "rip: the README Uninstall block exited 0 under load" "$(cat "$script.rc" 2>/dev/null)" 0
      t "rip: thinkfan stopped within 10 s ($([ -n "$stopped" ] && echo "${stopped}s"))" "$([ -n "$stopped" ] && [ "$stopped" -le 10 ] && echo yes || echo no)" yes
      t "rip: the fan went back to the firmware ('auto') within 10 s ($([ -n "$auto" ] && echo "${auto}s"))" "$([ -n "$auto" ] && [ "$auto" -le 10 ] && echo yes || echo no)" yes
      t "rip: the CPU never reached the safety stop after the removal (highest ${mx}C hottest)" "$tripped" 0
      t "rip: the plugin is really gone" "$(plugin_state | grep -c .)" 0
    fi
    rm -f "$script" "$script.rc"
  fi
fi

finish
