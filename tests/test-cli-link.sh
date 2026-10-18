#!/bin/bash
# Tier: local. The plugin links its command and man page into ~/.local on start. Runs the follower in a throwaway HOME
# (never touches yours) and checks the linking rules, and that the follower leaves no dbus-monitor behind. Needs a ThinkPad (the follower exits early elsewhere).
# No root, no fan changes.
. "$(dirname "$(readlink -f "$0")")/lib.sh"
is_thinkpad || suite_skip "not a ThinkPad (the follower exits before it makes any link)"
follow=$ROOT/bin/omarchy-fan-follow
cli=$ROOT/bin/omarchyfan
man1=$ROOT/man/omarchyfan.1

# start the follower for a moment: the links are made first, then it waits for the lock, so a short timeout is enough
# (XDG_RUNTIME_DIR is a scratch dir too, so it can't collide with the real follower)
run() { HOME=$1 XDG_RUNTIME_DIR=$1/run timeout 3 bash "$follow" >/dev/null 2>&1; }
newhome() { d=$(mktemp -d); mkdir -p "$d/run"; echo "$d"; }

echo "-- omarchyfan: command and man-page links"
h=$(newhome); run "$h"
t "fresh home: command link created" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
t "the link runs the command" "$(HOME=$h "$h/.local/bin/omarchyfan" current 2>/dev/null | head -1 | grep -cE '^(quiet|balanced|performance|manual)$')" 1
t "man page link created" "$(readlink "$h/.local/share/man/man1/omarchyfan.1")" "$man1"
t "man finds the page through the link" "$(man -M "$h/.local/share/man" -w omarchyfan 2>/dev/null | grep -c 'omarchyfan.1$')" 1
run "$h"
t "a second start changes nothing" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin" "$h/.local/share/man/man1"
echo "my own tool" > "$h/.local/bin/omarchyfan"; echo "my own page" > "$h/.local/share/man/man1/omarchyfan.1"   # planted BEFORE the run
run "$h"
t "a real file with that name is left alone" "$(cat "$h/.local/bin/omarchyfan")" "my own tool"
t "a real man page with that name is left alone" "$(cat "$h/.local/share/man/man1/omarchyfan.1")" "my own page"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin" "$h/.local/share/man/man1"
ln -s /nonexistent/old-plugin/omarchyfan "$h/.local/bin/omarchyfan"; ln -s /nonexistent/old-plugin/omarchyfan.1 "$h/.local/share/man/man1/omarchyfan.1"; run "$h"
t "a dangling command link is repaired" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
t "a dangling man link is repaired" "$(readlink "$h/.local/share/man/man1/omarchyfan.1")" "$man1"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /bin/true "$h/.local/bin/omarchyfan"; run "$h"
t "a link pointing somewhere else is replaced" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
rm -rf "$h"

echo "-- the follower leaves no dbus-monitor behind (a stray one used to survive a hard kill and live for days)"
if ! command -v dbus-monitor >/dev/null || ! command -v pgrep >/dev/null; then skip "monitor cleanup (needs dbus-monitor and pgrep)"
else
  MON="dbus-monitor --system type='signal',interface='org.freedesktop.DBus.Properties',sender='net.hadess.PowerProfiles'"
  # start a follower in its own scratch home; sets fpid and mpid (its dbus-monitor, which is a direct child) and fhome
  start_follower() {
    fhome=$(newhome)
    HOME=$fhome XDG_RUNTIME_DIR=$fhome/run bash "$follow" >/dev/null 2>&1 &
    fpid=$!; mpid=""
    for _ in $(seq 1 30); do mpid=$(pgrep -P "$fpid" -f "$MON" | head -1); [ -n "$mpid" ] && break; sleep 0.2; done
  }
  gone() { local _; for _ in $(seq 1 15); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done; return 1; }   # up to 3 s

  start_follower
  t "a follower started in a scratch home has its own dbus-monitor" "$([ -n "$mpid" ] && echo yes || echo no)" yes
  kill -TERM "$fpid"; { wait "$fpid"; } 2>/dev/null
  t "after a clean stop (TERM) its monitor is gone" "$(gone "$mpid" && echo yes || echo no)" yes
  rm -rf "$fhome"

  if command -v setpriv >/dev/null; then
    start_follower
    kill -KILL "$fpid"; { wait "$fpid"; } 2>/dev/null
    t "after a hard kill (KILL, nothing can clean up) its monitor is gone too" "$(gone "$mpid" && echo yes || echo no)" yes
    rm -rf "$fhome"
  else
    skip "hard-kill cleanup (setpriv is not installed; the start-up cleanup below still heals a leftover)"
  fi

  # an orphan, as an old follower's hard kill left it: started detached, so it is re-parented away from any follower
  before=$(pgrep -u "$UID" -f "$MON" | tr '\n' ' ')
  ( setsid dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',sender='net.hadess.PowerProfiles',member='PropertiesChanged'" >/dev/null 2>&1 & )
  sleep 0.5
  stale=""; for p in $(pgrep -u "$UID" -f "$MON"); do case " $before " in *" $p "*) ;; *) stale=$p ;; esac; done
  if [ -z "$stale" ]; then skip "orphan cleanup (could not plant an orphaned monitor)"
  elif [ "$(ps -o comm= -p "$(ps -o ppid= -p "$stale" | tr -d ' ')" 2>/dev/null)" != systemd ]; then
    kill "$stale" 2>/dev/null; skip "orphan cleanup (this session's orphans are not re-parented to systemd, so the follower would leave it alone)"
  else
    start_follower
    t "a follower starting up removes an orphaned monitor left by an earlier one" "$(gone "$stale" && echo yes || echo no)" yes
    t "...and keeps its own monitor" "$(kill -0 "$mpid" 2>/dev/null && echo yes || echo no)" yes
    keep=yes; for p in $before; do kill -0 "$p" 2>/dev/null || keep=no; done
    t "...and leaves every monitor that has a live parent alone (such as the plugin's own)" "$keep" yes
    kill -TERM "$fpid"; { wait "$fpid"; } 2>/dev/null; rm -rf "$fhome"
    kill "$stale" 2>/dev/null
  fi
fi

# ======================================================================================================================
# LEGACY: delete everything from here to the end marker when the old omarchy-fan name is removed (see bin/omarchy-fan,
# man/omarchy-fan.1, and the legacy_link block in bin/omarchy-fan-follow).
legacy_tests() {
  local legacy=$ROOT/bin/omarchy-fan legacy_man=$ROOT/man/omarchy-fan.1 h
  echo "-- legacy omarchy-fan: kept working for now, removed in a future release"

  h=$(newhome); run "$h"
  t "command link created" "$(readlink "$h/.local/bin/omarchy-fan")" "$legacy"
  t "man link created" "$(readlink "$h/.local/share/man/man1/omarchy-fan.1")" "$legacy_man"
  t "man finds the old page" "$(man -M "$h/.local/share/man" -w omarchy-fan 2>/dev/null | grep -c 'omarchy-fan.1$')" 1
  t "answers like the new command" "$(HOME=$h "$h/.local/bin/omarchy-fan" current 2>/dev/null)" "$(HOME=$h "$cli" current)"
  t "passes arguments through (a bad level is refused with exit 1)" "$(HOME=$h "$h/.local/bin/omarchy-fan" manual 9 >/dev/null 2>&1; echo $?)" 1
  t "prints no notice when stderr is not a terminal" "$(HOME=$h "$h/.local/bin/omarchy-fan" current 2>&1 >/dev/null | wc -c)" 0
  if command -v script >/dev/null; then
    t "prints the notice in a terminal" "$(script -qec "HOME=$h $h/.local/bin/omarchy-fan current" /dev/null 2>&1 | grep -c 'old name')" 1
    t "the new command prints no notice in a terminal" "$(script -qec "HOME=$h $cli current" /dev/null 2>&1 | grep -c 'old name')" 0
  else
    skip "terminal notice checks (the 'script' tool is not installed)"
  fi
  rm -rf "$h"

  # a v1.0.0 install already has links pointing at .../thinkpad-fan/bin/omarchy-fan: they are re-pointed at the current file
  h=$(newhome); mkdir -p "$h/.local/bin" "$h/.local/share/man/man1"
  ln -s /x/io.github.gunz0blazin.thinkpad-fan/bin/omarchy-fan "$h/.local/bin/omarchy-fan"
  ln -s /x/io.github.gunz0blazin.thinkpad-fan/man/omarchy-fan.1 "$h/.local/share/man/man1/omarchy-fan.1"
  run "$h"
  t "an old v1.0.0 command link is repaired" "$(readlink "$h/.local/bin/omarchy-fan")" "$legacy"
  t "an old v1.0.0 man link is repaired" "$(readlink "$h/.local/share/man/man1/omarchy-fan.1")" "$legacy_man"
  rm -rf "$h"

  # somebody else's working link, and a real file, are left alone; somebody else's broken link is repaired
  h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /bin/true "$h/.local/bin/omarchy-fan"; run "$h"
  t "someone else's working link is left alone" "$(readlink "$h/.local/bin/omarchy-fan")" "/bin/true"
  rm -rf "$h"
  h=$(newhome); mkdir -p "$h/.local/bin"; echo "my own tool" > "$h/.local/bin/omarchy-fan"; run "$h"
  t "a real file named omarchy-fan is left alone" "$(cat "$h/.local/bin/omarchy-fan")" "my own tool"
  rm -rf "$h"
  h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /nonexistent/elsewhere/omarchy-fan "$h/.local/bin/omarchy-fan"; run "$h"
  t "a broken link is repaired" "$(readlink "$h/.local/bin/omarchy-fan")" "$legacy"
  rm -rf "$h"
}
[ -x "$ROOT/bin/omarchy-fan" ] && [ -f "$ROOT/man/omarchy-fan.1" ] && legacy_tests
# END LEGACY
# ======================================================================================================================

finish
