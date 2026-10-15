#!/bin/bash
# full-test: the single runner for the whole test stack. Every test script still runs on its own (bash tests/<name>.sh); this
# runs the right ones, in the right order, with a pass/fail table and one exit code.
#
#   bash tests/full-test.sh                 the COMMIT check, every commit (about 10 seconds; read-only: README and manifest still
#                                           match the code, nothing crashes, no fan, no plugin, no sudo)
#   bash tests/full-test.sh --quick         commit + the package and CLI-link suites (about 35 seconds; still read-only)
#   bash tests/full-test.sh --base          quick + the device suites: before merging to main (about 3.5 minutes; budget 4)
#   bash tests/full-test.sh --release       base + a clean uninstall/reinstall and the marketplace's own security scanner on the pushed
#                                           commit: before merging to main (about 8 minutes; needs network)
#   bash tests/full-test.sh --list          what is in each level, how long it takes, what it needs
#   bash tests/full-test.sh --only id,id    just these (ids from --list)
#   bash tests/full-test.sh --sync [REF]    first make the installed plugin and root helper match origin/REF (default dev) and
#                                           restart the shell, so the device runs exactly what was pushed
# The read-only suites run in parallel with the device suites. Exit status: 0 = nothing failed (skips and known gaps are allowed),
# 1 = something failed or timed out.
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
ROOT=$PWD
ID=io.github.gunz0blazin.thinkpad-fan
PDIR=~/.config/omarchy/plugins/$ID
BUDGET=240     # seconds the base suite must stay under

# the registry: the one place that decides what runs when.   id | script | env | level | seconds | limit(s) | needs | what it proves
#   level: commit = fast read-only checks, every commit (~10 s); quick = the other read-only suites (~35 s in all);
#          base = the device suites, before a merge to main; release = base + uninstall + marketplace scanner
REGISTRY='check|check.sh||commit|5|240|-|manifest, shell syntax, executable bits, man-page lint, curve files, profile safety rule, QML lint
marketplace|check-marketplace.sh||commit|5|240|-|the marketplace publishing, development and security-baseline rules
readme|test-readme.sh||commit|5|240|-|README and man page match the code, the paths, the curve numbers, the test list
package|test-package.sh||quick|5|300|makepkg|the root-helper package: exact files, owners, modes, polkit policy, no sudoers rule
compat|test-compat.sh||commit|5|240|-|doctor and stats over the T480s capture and 13 fake machines (other ThinkPads, broken and non-ThinkPad)
cli-link|test-cli-link.sh||quick|35|240|-|the command and man-page links the plugin makes, in a fake home
panel|test-panel.sh||base|30|420|plugin in the bar|the panel opens/closes (also Escape), no shell-log errors, survives disable and re-enable
follow|test-follow.sh||base|30|300|plugin in the bar|the power-profile follower reacts, stays single, leaves AC alone
helper|test-helper.sh||base|15|420|helper, thinkfan|each curve applies, manual levels reach the kernel, rapid restarts, bad input rejected
effect|test-effect.sh||base|60|420|helper, thinkfan|the fan really speeds up, slows down and stops (RPM, not just the level)
safety-net|test-safety.sh|PARTS=net|base|10|300|sudo|every pinned manual level gets the full-speed safety row (config)
safety-reload|test-safety.sh|PARTS=reload|base|20|600|sudo|reloading the thinkpad_acpi driver leaves LEDs, battery limits, hotkeys and radios intact
safety-handoff|test-safety.sh|PARTS=handoff|base|20|300|sudo|when thinkfan stops or is disabled (what removing the plugin does) the firmware takes the fan back within 10 s
uninstall|test-uninstall.sh||release|300|1200|sudo, network|the README Uninstall leaves nothing on the system; the plugin reinstalls
scan|check-marketplace.sh|MARKETPLACE_SCAN=1|release|20|300|network, node, pushed commit|the official marketplace security scanner on the pushed commit: no findings, no new capability'

ro() { [ "$1" = commit ] || [ "$1" = quick ]; }   # the read-only levels run in parallel
level_of() { case "$1" in commit) echo 1;; quick) echo 2;; base) echo 3;; release) echo 4;; *) echo 9;; esac; }
want_level=1; only=""; sync=""; ref=dev; list=0
while [ $# -gt 0 ]; do case "$1" in
  --quick) want_level=2 ;; --base) want_level=3 ;; --release) want_level=4 ;; --list) list=1 ;; --only) only=$2; shift ;; --only=*) only=${1#--only=} ;;
  --sync) sync=1; case "$2" in ""|--*) ;; *) ref=$2; shift ;; esac ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (try --help)"; exit 2 ;; esac; shift; done

if [ "$list" = 1 ]; then
  printf '%-15s %-8s %5s  %-26s %s\n' ID LEVEL SEC NEEDS "WHAT IT PROVES"
  echo "$REGISTRY" | while IFS='|' read -r id script env level min limit needs what; do printf '%-15s %-8s %5s  %-26s %s\n' "$id" "$level" "$min" "$needs" "$what"; done
  # the read-only suites run in parallel, so they cost only as much as the slowest one
  echo "$REGISTRY" | awk -F'|' '{ m[$4]+=$5; if ($5>mx[$4]) mx[$4]=$5 } END { c=mx["commit"]; q=(mx["quick"]>c)?mx["quick"]:c; b=(q>m["base"])?q:m["base"]; r=b+m["release"]; printf "\nwall-clock estimate (measured; the read-only suites overlap the device suites): commit ~%ds, quick ~%dm%02ds, base ~%dm%02ds (budget 4m00s), release ~%dm%02ds\n", c, q/60, q%60, b/60, b%60, r/60, r%60 }'
  echo "(each script also runs by itself: bash tests/<script>)"; exit 0
fi

# ---------- pick the suites ----------
selected=""
while IFS='|' read -r id script env level min limit needs what; do
  if [ -n "$only" ]; then case ",$only," in *",$id,"*) ;; *) continue ;; esac
  else [ "$(level_of "$level")" -le "$want_level" ] || continue; fi
  selected="$selected$id|$script|$env|$level|$min|$limit|$needs|$what"$'\n'
done <<<"$REGISTRY"
[ -n "$selected" ] || { echo "nothing selected"; exit 2; }
for f in tests/*.sh; do b=$(basename "$f"); [ "$b" = lib.sh ] || [ "$b" = full-test.sh ] || echo "$REGISTRY" | cut -d'|' -f2 | grep -qx "$b" || echo "WARNING: $b is not in the full-test registry"; done

# ---------- optional: put the device on exactly what was pushed ----------
if [ -n "$sync" ]; then
  echo "== sync: installed plugin and helper -> origin/$ref"
  if [ -d "$PDIR/.git" ]; then
    git -C "$PDIR" fetch -q origin && git -C "$PDIR" checkout -q -B "$ref" "origin/$ref" && git -C "$PDIR" branch -u "origin/$ref" >/dev/null 2>&1
    echo "   plugin folder: $(git -C "$PDIR" branch --show-current) @ $(git -C "$PDIR" rev-parse --short HEAD)"
  else echo "   the plugin is not installed: the device suites will skip"; fi
  if [ -d "$PDIR/packaging" ] && { ! cmp -s /usr/lib/omarchy-fan/helper "$PDIR/helper/omarchy-fan-helper" || ! diff -rq "$PDIR/profiles" /usr/share/omarchy-fan/profiles >/dev/null 2>&1; }; then
    echo "   the installed helper or curves differ from origin/$ref: rebuilding the package (needs sudo)"
    ( cd "$PDIR/packaging" && yes | makepkg -sif >/dev/null 2>&1 ) && echo "   installed $(pacman -Q omarchy-fan-helper)" || echo "   !! the package build failed"
  else echo "   helper and curves already match"; fi
  omarchy restart shell >/dev/null 2>&1; sleep 6; echo "   shell restarted"
fi

# ---------- banner ----------
sha=$(git rev-parse --short HEAD 2>/dev/null); branch=$(git branch --show-current 2>/dev/null); dirty=$(git status --short 2>/dev/null | wc -l)
plug=$(git -C "$PDIR" rev-parse --short HEAD 2>/dev/null)
logdir=$(mktemp -d "${TMPDIR:-/tmp}/omarchyfan-full-test.XXXXXX")
lvl_name=$([ -n "$only" ] && echo "only $only" || case $want_level in 1) echo commit;; 2) echo quick;; 3) echo base;; 4) echo release;; esac)
echo "=============================================================================="
echo " omarchyfan full-test   $(date '+%F %T')   level: $lvl_name"
echo " under test:   $branch @ $sha ($dirty uncommitted files)    installed plugin: ${plug:-none}$([ -n "$plug" ] && [ "$plug" != "$sha" ] && echo "  (differs from the checkout: the device suites test the INSTALLED plugin; use --sync to align)")"
echo " machine:      $(cat /sys/class/dmi/id/product_version 2>/dev/null), AC=$(cat /sys/class/power_supply/AC/online 2>/dev/null), CPU $(awk '/^temperatures:/{print $2}' /proc/acpi/ibm/thermal 2>/dev/null)C, $(echo "$selected" | grep -c .) suites"
echo " logs:         $logdir"
echo "=============================================================================="

# ---------- run ----------
run_one() {   # <id> <script> <env> <limit>: runs one suite and records "rc|seconds|passed|failed|skipped|gaps|word" in $logdir/<id>.res
  local id=$1 script=$2 env=$3 limit=$4 t0=$SECONDS rc sum p f s g word
  ( cd "$ROOT" && env ${env:+"$env"} timeout "$limit" bash "tests/$script" ) > "$logdir/$id.log" 2>&1; rc=$?
  sum=$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$logdir/$id.log" | tail -1)
  p=$(sed -n 's/^\([0-9]*\) passed.*/\1/p' <<<"$sum"); f=$(sed -n 's/.*, \([0-9]*\) failed.*/\1/p' <<<"$sum"); s=$(sed -n 's/.*, \([0-9]*\) skipped.*/\1/p' <<<"$sum"); g=$(sed -n 's/.*, \([0-9]*\) known gap.*/\1/p' <<<"$sum")
  case $rc in 0) word=PASS ;; 77) word="SKIPPED: $(grep -m1 '^SKIPPED' "$logdir/$id.log" | cut -c10-90)" ;; 124) word="TIMED OUT after ${limit}s" ;; *) word=FAIL ;; esac
  echo "$rc|$((SECONDS - t0))|${p:-0}|${f:-0}|${s:-0}|${g:-0}|$word" > "$logdir/$id.res"
}
total_p=0; total_f=0; total_s=0; total_g=0; bad=0; rows=""; t_start=$SECONDS
show_one() {  # <id> <what>: prints one finished suite and adds it to the totals
  local id=$1 what=$2 rc dt p f s g word icon
  IFS='|' read -r rc dt p f s g word < "$logdir/$id.res"
  case $rc in 0) icon="🟢" ;; 77) icon="⚪" ;; *) icon="🔴"; bad=$((bad+1)) ;; esac
  total_p=$((total_p + p)); total_f=$((total_f + f)); total_s=$((total_s + s)); total_g=$((total_g + g))
  printf '\n▶ %s  %s\n  %s %s   🟢 %s passed  🔴 %s failed  ⚪ %s skipped%s   (%ss)\n' "$id" "$what" "$icon" "$word" "$p" "$f" "$s" "$([ "$g" -gt 0 ] && echo "  🟡 $g known gap(s)")" "$dt"
  [ "$rc" -ne 0 ] && [ "$rc" -ne 77 ] && grep -E '^\s+(FAIL|🔴 FAIL)' "$logdir/$id.log" | head -6 | sed 's/^/     /' | cut -c1-170
  rows="$rows$icon|$id|$p|$f|$s|$g|${dt}s|$word"$'\n'
}
# the read-only suites run in parallel with everything else
qpids=""
while IFS='|' read -r id script env level min limit needs what; do
  [ -n "$id" ] && ro "$level" || continue
  run_one "$id" "$script" "$env" "$limit" & qpids="$qpids $!"
done <<<"$selected"
[ -n "$qpids" ] && echo "(read-only suites running in the background while the device suites run)"
# the device suites run one after the other (they share the fan, the shell and the plugin)
while IFS='|' read -r id script env level min limit needs what; do
  [ -n "$id" ] && ! ro "$level" || continue
  run_one "$id" "$script" "$env" "$limit"; show_one "$id" "$what"
done <<<"$selected"
[ -n "$qpids" ] && wait $qpids
while IFS='|' read -r id script env level min limit needs what; do
  [ -n "$id" ] && ro "$level" || continue
  show_one "$id" "$what"
done <<<"$selected"

# ---------- summary ----------
elapsed=$((SECONDS - t_start))
echo; echo "=============================================================================="
printf ' %-2s %-16s %7s %7s %8s %6s %8s\n' "" SUITE PASSED FAILED SKIPPED GAPS TIME
echo "$rows" | while IFS='|' read -r icon id p f s g dt word; do [ -n "$id" ] && printf ' %-2s %-16s %7s %7s %8s %6s %8s  %s\n' "$icon" "$id" "$p" "$f" "$s" "$g" "$dt" "$(case "$word" in PASS) ;; *) echo "$word";; esac)"; done
echo "------------------------------------------------------------------------------"
printf ' %-19s %7s %7s %8s %6s %8s\n' TOTAL "$total_p" "$total_f" "$total_s" "$total_g" "$((elapsed / 60))m$((elapsed % 60))s"
if [ $bad -eq 0 ]; then echo " 🟢 FULL TEST PASSED   $branch @ $sha   ($total_p checks passed, $total_s skipped, $total_g known gap(s))"
else echo " 🔴 FULL TEST FAILED   $bad suite(s) failed   logs: $logdir"; fi
[ "$want_level" -le 3 ] && [ -z "$only" ] && [ "$elapsed" -gt "$BUDGET" ] && echo " ⚠️  over the 4-minute budget: $((elapsed / 60))m$((elapsed % 60))s"
echo "=============================================================================="
exit $([ $bad -eq 0 ] && echo 0 || echo 1)
