#!/bin/bash
# The plugin links its command into ~/.local/bin on start. Runs the follower in a throwaway HOME (never touches
# yours) and checks the linking rules. Needs a ThinkPad (the follower exits early elsewhere). No root, no fan changes.
here=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
follow=$here/bin/omarchy-fan-follow
cli=$here/bin/omarchy-fan
pass=0; failn=0
t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (got '$2', want '$3')"; failn=$((failn+1)); fi; }

[ -d /sys/devices/platform/thinkpad_acpi ] || { echo "skip: not a ThinkPad"; exit 0; }

# start the follower for a moment: the link is made first, then it waits for the lock, so a short timeout is enough
# (XDG_RUNTIME_DIR is a scratch dir too, so it can't collide with the real follower)
run() { HOME=$1 XDG_RUNTIME_DIR=$1/run timeout 3 bash "$follow" >/dev/null 2>&1; }
newhome() { d=$(mktemp -d); mkdir -p "$d/run"; echo "$d"; }

h=$(newhome); run "$h"
t "fresh home: link created" "$(readlink "$h/.local/bin/omarchy-fan")" "$cli"
t "link runs the CLI" "$(HOME=$h "$h/.local/bin/omarchy-fan" current 2>/dev/null | head -1 | grep -cE '^(quiet|balanced|performance|manual)$')" 1
run "$h"
t "second start is idempotent" "$(readlink "$h/.local/bin/omarchy-fan")" "$cli"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; echo "my own tool" > "$h/.local/bin/omarchy-fan"; run "$h"
t "a real file with that name is left alone" "$(cat "$h/.local/bin/omarchy-fan")" "my own tool"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /nonexistent/old-plugin/omarchy-fan "$h/.local/bin/omarchy-fan"; run "$h"
t "dangling link is repaired" "$(readlink "$h/.local/bin/omarchy-fan")" "$cli"
rm -rf "$h"

h=$(newhome); mkdir -p "$h/.local/bin"; ln -s /bin/true "$h/.local/bin/omarchy-fan"; run "$h"
t "link to somewhere else is replaced" "$(readlink "$h/.local/bin/omarchy-fan")" "$cli"
rm -rf "$h"

echo "$pass passed, $failn failed"
[ $failn = 0 ]
