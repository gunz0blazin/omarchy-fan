#!/bin/bash
# Tier: static. Runs `omarchyfan doctor` and `stats` against fake /proc and /sys trees (tests/fixtures/*) to check how
# the plugin reads other ThinkPad models and what it says on machines it can't support. Reads files only, no fan or
# system changes, works on any machine. (The "setup" line also depends on what is installed on the host, so only
# whether it says "unsupported" is checked.)
. "$(dirname "$(readlink -f "$0")")/lib.sh"
FX=$ROOT/tests/fixtures
[ -d "$FX" ] || suite_skip "no tests/fixtures folder in this version"
"$CLI" doctor >/dev/null 2>&1; [ $? -le 1 ] || suite_skip "this version has no 'doctor' command"

doc()   { OMARCHYFAN_ROOT=$FX/$1 "$CLI" doctor 2>&1; }
stat_() { OMARCHYFAN_ROOT=$FX/$1 "$CLI" stats 2>&1 | awk -F'\t' -v k="$2" '$1==k{print $2}'; }
has()   { grep -qE -- "$2" <<<"$1" && echo yes || echo no; }
rc()    { OMARCHYFAN_ROOT=$FX/$1 "$CLI" doctor >/dev/null 2>&1; echo $?; }

echo "-- the tested machine (real capture)"
d=$(doc t480s)
t "doctor passes (exit 0)" "$(rc t480s)" 0
t "names the machine" "$(has "$d" 'ThinkPad T480s')" yes
t "no FAIL lines" "$(has "$d" '^FAIL')" no
t "levels 0-7 recognised" "$(has "$d" 'ok +fan levels 0-7')" yes
t "stats: not unsupported" "$([ "$(stat_ t480s setup)" = unsupported ] && echo yes || echo no)" no
t "stats: temperature read from the first slot" "$(stat_ t480s temp)" 39
t "stats: rpm 0" "$(stat_ t480s rpm)" 0

echo "-- other ThinkPad shapes"
d=$(doc t14-amd)
t "AMD-style: fewer sensors, still supported (exit 0)" "$(rc t14-amd)" 0
t "AMD-style: temp 52" "$(stat_ t14-amd temp)" 52
t "AMD-style: rpm 2400" "$(stat_ t14-amd rpm)" 2400
d=$(doc p1-dual-fan)
t "dual fan: still supported (exit 0)" "$(rc p1-dual-fan)" 0
t "dual fan: both fans follow the level when the kernel controls fan2" "$(has "$d" 'ok +second fan \(fan2\): the kernel sets each fan level on both fans')" yes
t "dual fan: no mirror note when fan2 reads 0" "$(has "$d" 'probably one fan reported twice')" no
d=$(doc dual-fan-mirror)
t "mirrored fan2: still supported (exit 0)" "$(rc dual-fan-mirror)" 0
t "mirrored fan2: says it can't tell from the kernel log" "$(has "$d" "warn +second fan \(fan2\) is reported; the kernel log doesn't say")" yes
t "mirrored fan2: notes one fan reported twice" "$(has "$d" 'fan2 reads exactly like fan1 \(3268 RPM\)')" yes
d=$(doc dual-fan-no-ctl)
t "fan2 without control: warns only the first follows" "$(has "$d" "warn +second fan \(fan2\) is reported, but the kernel can't set its level")" yes
d=$(doc dual-fan-read-only)
t "fan2 readable only ('support enabled'): warns only the first follows" "$(has "$d" "warn +second fan \(fan2\) is reported, but the kernel can't set its level")" yes
d=$(doc dual-fan-ctl-lost)
t "fan2 control lost after boot ('Couldn't set 2nd fan level'): warns, no ok" "$(has "$d" 'warn +second fan \(fan2\): the kernel failed to set its level')" yes
t "fan2 control lost after boot: the earlier 'enabled' line doesn't count" "$(has "$d" 'ok +second fan')" no
d=$(doc fan-control-off)
t "fan_control off: supported, with a warning (exit 0)" "$(rc fan-control-off)" 0
t "fan_control off: warns" "$(has "$d" 'warn +fan_control is off')" yes
t "fan_control off: setup is not 'ready'" "$([ "$(stat_ fan-control-off setup)" = ready ] && echo ready || echo notready)" notready
d=$(doc speed-glitch)
t "65535 speed: not shown as an RPM" "$(stat_ speed-glitch rpm)" ""
t "65535 speed: doctor explains it (exit 0)" "$(has "$d" 'warn +fan speed reads 65535')$(rc speed-glitch)" yes0
d=$(doc odd-levels)
t "levels 0-9: warns the profiles assume 0-7" "$(has "$d" 'warn +fan levels are 0-9')" yes

echo "-- the helper package version (doctor says when the installed helper is older than the plugin's)"
if [ -x /usr/lib/omarchy-fan/helper ]; then
  d=$(OMARCHYFAN_HELPER_VERSION=0.0.1-1 OMARCHYFAN_ROOT=$FX/t480s "$CLI" doctor 2>&1)
  t "an older installed helper: doctor warns, with both versions" "$(has "$d" 'warn +root helper 0\.0\.1-1 is older than the [0-9.]+-[0-9]+ this plugin ships')" yes
  t "an older installed helper: doctor says what to press" "$(has "$d" "Update fan control")" yes
  d=$(OMARCHYFAN_HELPER_VERSION=99.0-1 OMARCHYFAN_ROOT=$FX/t480s "$CLI" doctor 2>&1)
  t "a newer installed helper: no warning, the version is shown" "$(has "$d" 'ok +root helper is installed \(99\.0-1\)')" yes
else
  skip "helper version checks (the root helper is not installed on this machine)"
fi
echo "-- broken or missing pieces: clear failures, no crash"
d=$(doc bad-first-sensor)
t "first sensor unusable: FAIL, exit 1" "$(rc bad-first-sensor)" 1
t "first sensor unusable: says why" "$(has "$d" "FAIL +the first temperature reads '-128'")" yes
d=$(doc no-fan-file)
t "no fan file: FAIL, exit 1" "$(rc no-fan-file)" 1
t "no fan file: says so" "$(has "$d" 'FAIL +/proc/acpi/ibm/fan is missing')" yes
t "no fan file: stats still run, rpm empty" "$(stat_ no-fan-file rpm)" ""
d=$(doc no-thermal-file)
t "no thermal file: FAIL, exit 1" "$(rc no-thermal-file)" 1
t "no thermal file: stats temp empty" "$(stat_ no-thermal-file temp)" ""

echo "-- not a ThinkPad"
d=$(doc not-a-thinkpad)
t "unsupported machine: doctor FAIL, exit 1" "$(rc not-a-thinkpad)" 1
t "names the machine" "$(has "$d" 'Dell Inc\. XPS 13')" yes
t "says the driver is missing" "$(has "$d" 'FAIL +thinkpad_acpi is not loaded')" yes
t "stats: setup = unsupported" "$(stat_ not-a-thinkpad setup)" unsupported
t "status prints without errors" "$(OMARCHYFAN_ROOT=$FX/not-a-thinkpad "$CLI" status 2>&1 | grep -c 'setup: unsupported')" 1

finish
