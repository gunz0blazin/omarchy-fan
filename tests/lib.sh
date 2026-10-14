#!/bin/bash
# Shared helpers for the test scripts. Source this file; don't run it.
#
# Test tiers (what a script may touch):
#   static       reads files only                      check.sh, check-marketplace.sh, test-readme.sh, test-package.sh
#   local        fake home directory, no system change test-cli-link.sh
#   shell        briefly uses/disables the plugin in your running bar   test-panel.sh, test-follow.sh
#   hardware     changes your fan (and power profile), then restores it test-helper.sh, test-effect.sh
#   destructive  needs sudo, stops thinkfan / reloads the driver        test-failsafe.sh
#
# A suite that cannot run on this machine exits 77 ("skipped"); single skipped checks are counted and printed, so a
# skip can never be mistaken for a pass.

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ID=io.github.gunz0blazin.thinkpad-fan

# The command in this checkout: omarchyfan, or omarchy-fan on versions from before the rename, so the same tests can
# run against either. Override with CLI=/path/to/command.
CLI=${CLI:-}
if [ -z "$CLI" ]; then
  for c in omarchyfan omarchy-fan; do
    [ -x "$ROOT/bin/$c" ] && { CLI=$ROOT/bin/$c; break; }
  done
fi
CMD=$(basename "${CLI:-omarchyfan}")

pass=0; failn=0; skipn=0; gapn=0
t()    { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (got '$2', want '$3')"; failn=$((failn+1)); fi; }
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; failn=$((failn+1)); }
skip() { echo "  SKIP  $1"; skipn=$((skipn+1)); }
info() { echo "  INFO  $1"; }
# a documented limitation we know about and have not fixed: shown in the summary, does not fail the run
gap()  { echo "  GAP   $1"; gapn=$((gapn+1)); }
suite_skip() { echo "SKIPPED: $1"; exit 77; }
finish() { echo "$pass passed, $failn failed, $skipn skipped$([ "$gapn" -gt 0 ] && echo ", $gapn known gap(s)")"; [ "$failn" = 0 ]; }

is_thinkpad() { [ -d /sys/devices/platform/thinkpad_acpi ]; }
on_ac()       { [ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = 1 ]; }
fan_rpm()     { awk '$1=="speed:"{ if ($2<=20000) print $2 }' /proc/acpi/ibm/fan 2>/dev/null; }   # 65535 = no reading
fan_level()   { awk '$1=="level:"{print $2}' /proc/acpi/ibm/fan 2>/dev/null; }
cpu_temp()    { awk '/^temperatures:/{print $2}' /proc/acpi/ibm/thermal 2>/dev/null; }
setup_state() { "$CLI" stats 2>/dev/null | awk -F'\t' '$1=="setup"{print $2}'; }
plugin_state(){ omarchy plugin list 2>/dev/null | awk -v id="$ID" '$1==id{print $2}'; }
follower_count() { pgrep -f '^/usr/bin/bash [^ ]*/bin/omarchy-fan-follow$' | wc -l; }
