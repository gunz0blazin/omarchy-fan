#!/bin/bash
# Tier: destructive (stops thinkfan and reloads the thinkpad_acpi driver for a few seconds; nothing is loaded or heated).
# THE SAFETY TEST: three fast checks that the plugin leaves a user's laptop in a safe, working state. About one minute.
# Run them all, or pick: PARTS="net handoff" bash tests/test-safety.sh
#   net      every pinned manual level 0-7 gets a full-speed safety row (80 C and up), level 8 is a single full-speed row
#   reload   reloading the thinkpad_acpi driver (the boot hook / "Enable fan control") leaves LEDs, battery limits, hotkeys,
#            input devices and radios exactly as they were, and the fan answers afterwards
#   handoff  when thinkfan stops or is disabled (what removing the plugin does) the fan goes back to the firmware within 10 s
# Needs: a ThinkPad with fan control set up, and passwordless sudo. Restores everything, also if interrupted.
PARTS=${PARTS:-"net reload handoff"}
want() { case " $PARTS " in *" $1 "*) return 0;; esac; return 1; }
. "$(dirname "$(readlink -f "$0")")/lib.sh"
PDIR=~/.config/omarchy/plugins/$ID; CLI=$PDIR/bin/omarchyfan
TA=/sys/devices/platform/thinkpad_acpi

is_thinkpad || suite_skip "not a ThinkPad"
[ -d "$PDIR" ] && [ -x "$CLI" ] || suite_skip "the plugin is not installed (this test uses the installed plugin)"
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
sudo -n true 2>/dev/null || suite_skip "needs passwordless sudo"
[ "${temp0:=$(cpu_temp)}" -le 70 ] || suite_skip "the CPU is warm (${temp0}C): run this on an idle laptop"

orig=$("$CLI" current); manual=$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 0)
nofollow=$([ -e ~/.config/omarchy/fan/no-follow ] && echo yes || echo no); was_enabled=$(systemctl is-enabled thinkfan 2>/dev/null)
restore() {
  trap - EXIT
  sudo -n systemctl reset-failed thinkfan >/dev/null 2>&1
  [ "$was_enabled" = enabled ] && sudo -n systemctl enable --now thinkfan >/dev/null 2>&1
  sudo -n systemctl start thinkfan >/dev/null 2>&1; sleep 2
  if [ "$nofollow" = yes ]; then "$CLI" follow off >/dev/null 2>&1; else "$CLI" follow on >/dev/null 2>&1; fi
  case "$orig" in manual) "$CLI" manual "$manual" ;; *) "$CLI" "$orig" ;; esac >/dev/null 2>&1
}
trap restore EXIT
"$CLI" follow off >/dev/null 2>&1    # a power-profile change must not move the fan during the test

# ====================================================================================================== net
if want net; then
  echo "== net: a pinned fan level can never leave a hot CPU without full fan"
  for n in 0 1 3 7; do
    "$CLI" manual $n >/dev/null; sleep 2; y=$(cat /etc/thinkfan.yaml)
    t "manual $n: the pinned row goes up to 85 C" "$(grep -c "^  - \[$n, 0, 85\]" <<<"$y")" 1
    t "manual $n: the safety row goes to full speed at 80 C and up" "$(grep -c '^  - \["level full-speed", 80, 32767\]' <<<"$y")" 1
    t "manual $n: thinkfan accepts the config" "$(systemctl is-active thinkfan)" active
  done
  "$CLI" manual 8 >/dev/null; sleep 2
  t "manual 8 (full speed) is a single full-speed row" "$(grep -c '^  - \[' /etc/thinkfan.yaml)" 1
  t "manual 8: thinkfan accepts the config" "$(systemctl is-active thinkfan)" active
fi

# ====================================================================================================== reload
if want reload; then
  echo; echo "== reload: the thinkpad_acpi driver reload (boot hook / 'Enable fan control') is harmless"
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
  B=$(mktemp); snap | sort > "$B"; sudo -n dmesg -C >/dev/null 2>&1 || true
  for round in $(seq 1 ${ROUNDS:-1}); do
    sudo -n systemctl stop thinkfan; sleep 1
    sudo -n modprobe -r thinkpad_acpi; r1=$?; sudo -n modprobe thinkpad_acpi fan_control=1; r2=$?; sleep 2
    sudo -n systemctl start thinkfan; sleep 3
    t "round $round: the driver unloads and loads again cleanly" "$r1$r2" 00
    t "round $round: fan_control is back on and thinkfan runs" "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)/$(systemctl is-active thinkfan)" Y/active
    d=$(snap | sort | diff "$B" -); if [ -z "$d" ]; then ok "round $round: LEDs, battery limits, hotkeys, input devices, Wi-Fi and Bluetooth are identical to before"; else bad "round $round: these changed: $(echo "$d" | tr '\n' ' ' | cut -c1-200)"; fi
    "$CLI" manual 2 >/dev/null; sleep 3; t "round $round: the fan answers a command afterwards" "$(fan_level)" 2
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

# ====================================================================================================== handoff
if want handoff; then
  echo; echo "== handoff: when thinkfan goes away, the firmware takes the fan back quickly"
  for how in "stop" "disable --now"; do
    "$CLI" manual 2 >/dev/null; sleep 4
    t "before 'systemctl $how thinkfan': the plugin holds the fan at level 2" "$(fan_level)" 2
    t0=$SECONDS; sudo -n systemctl $how thinkfan; auto=""
    while [ $((SECONDS - t0)) -lt 15 ]; do [ "$(fan_level)" = auto ] && { auto=$((SECONDS - t0)); break; }; sleep 0.5; done
    t "after 'systemctl $how thinkfan' the fan is back with the firmware ('auto') within 10 s ($([ -n "$auto" ] && echo "${auto}s" || echo "not within 15 s"))" "$([ -n "$auto" ] && [ "$auto" -le 10 ] && echo yes || echo no)" yes
    t "thinkfan is really stopped" "$(systemctl is-active thinkfan)" inactive
    case "$how" in "disable --now") sudo -n systemctl enable --now thinkfan >/dev/null 2>&1 ;; *) sudo -n systemctl start thinkfan >/dev/null 2>&1 ;; esac; sleep 3
    t "starting it again gives the plugin the fan back (level 2)" "$(fan_level)" 2
  done
  t "the plugin reports setup ready afterwards" "$(setup_state)" ready
  t "thinkfan is enabled again, as before" "$(systemctl is-enabled thinkfan)" "${was_enabled:-enabled}"
fi

finish
