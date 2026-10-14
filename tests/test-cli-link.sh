#!/bin/bash
# The plugin links its command into ~/.local/bin on start. Runs the follower in a throwaway HOME (never touches
# yours) and checks the linking rules. Needs a ThinkPad (the follower exits early elsewhere). No root, no fan changes.
here=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
follow=$here/bin/omarchy-fan-follow
cli=$here/bin/omarchyfan
man1=$here/man/omarchyfan.1
pass=0; failn=0
t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (got '$2', want '$3')"; failn=$((failn+1)); fi; }

[ -d /sys/devices/platform/thinkpad_acpi ] || { echo "skip: not a ThinkPad"; exit 0; }

# start the follower for a moment: the link is made first, then it waits for the lock, so a short timeout is enough
# (XDG_RUNTIME_DIR is a scratch dir too, so it can't collide with the real follower)
run() { HOME=$1 XDG_RUNTIME_DIR=$1/run timeout 3 bash "$follow" >/dev/null 2>&1; }
newhome() { d=$(mktemp -d); mkdir -p "$d/run"; echo "$d"; }

h=$(newhome); run "$h"
t "fresh home: link created" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
t "link runs the CLI" "$(HOME=$h "$h/.local/bin/omarchyfan" current 2>/dev/null | head -1 | grep -cE '^(quiet|balanced|performance|manual)$')" 1
run "$h"
t "man page link created" "$(readlink "$h/.local/share/man/man1/omarchyfan.1")" "$man1"
t "man finds the page through the link" "$(man -M "$h/.local/share/man" -w omarchyfan 2>/dev/null | grep -c 'omarchyfan.1$')" 1
t "second start is idempotent" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin" "$h/.local/share/man/man1"
echo "my own tool" > "$h/.local/bin/omarchyfan"; echo "my own page" > "$h/.local/share/man/man1/omarchyfan.1"   # planted BEFORE the run
run "$h"
t "a real file with that name is left alone" "$(cat "$h/.local/bin/omarchyfan")" "my own tool"
t "a real man page with that name is left alone" "$(cat "$h/.local/share/man/man1/omarchyfan.1")" "my own page"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /nonexistent/old-plugin/omarchyfan "$h/.local/bin/omarchyfan"
mkdir -p "$h/.local/share/man/man1"; ln -s /nonexistent/old-plugin/omarchyfan.1 "$h/.local/share/man/man1/omarchyfan.1"; run "$h"
t "dangling link is repaired" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
t "dangling man link is repaired" "$(readlink "$h/.local/share/man/man1/omarchyfan.1")" "$man1"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /bin/true "$h/.local/bin/omarchyfan"; run "$h"
t "link to somewhere else is replaced" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
rm -rf "$h"

# the command used to be called omarchy-fan (hyphen): our old links are removed, anyone else's are not
gone() { [ -e "$1" ] || [ -L "$1" ] && echo present || echo gone; }
h=$(newhome); mkdir -p "$h/.local/bin" "$h/.local/share/man/man1"
ln -s /x/io.github.gunz0blazin.thinkpad-fan/bin/omarchy-fan "$h/.local/bin/omarchy-fan"
ln -s /x/io.github.gunz0blazin.thinkpad-fan/man/omarchy-fan.1 "$h/.local/share/man/man1/omarchy-fan.1"
run "$h"
t "old omarchy-fan command link (ours) is removed" "$(gone "$h/.local/bin/omarchy-fan")" gone
t "old omarchy-fan man link (ours) is removed" "$(gone "$h/.local/share/man/man1/omarchy-fan.1")" gone
t "new omarchyfan command link is in place" "$(readlink "$h/.local/bin/omarchyfan")" "$cli"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /bin/true "$h/.local/bin/omarchy-fan"; run "$h"
t "someone else's omarchy-fan link is left alone" "$(readlink "$h/.local/bin/omarchy-fan")" "/bin/true"
rm -rf "$h"

echo "$pass passed, $failn failed"
[ $failn = 0 ]
