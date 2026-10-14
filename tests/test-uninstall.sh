#!/bin/bash
# Tier: destructive. Runs the README's own "Uninstall" commands, then checks the system has nothing left of the plugin:
# no packages (helper, thinkfan, thinkfan-debug, orphaned dependencies), no files, no links, no saved state, no services,
# no entry in the bar. Afterwards it installs the plugin again from this checkout (a committed copy) and puts your
# profile and the icon's place in the bar back, also if interrupted.
# Needs: the plugin installed and set up, passwordless sudo, an idle cool laptop (<= 48C), network (thinkfan is rebuilt
# from the AUR when it is put back). Takes a few minutes. The tests/ folder is copied away first, because the
# uninstall deletes the plugin folder this script would otherwise be running from.
if [ -z "$OMARCHYFAN_UNINSTALL_COPY" ]; then
  src=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
  copy=$(mktemp -d)
  cp -a "$src/." "$copy/"
  OMARCHYFAN_UNINSTALL_COPY=1 exec bash "$copy/tests/test-uninstall.sh" "$@"
fi
. "$(dirname "$(readlink -f "$0")")/lib.sh"
README=$ROOT/README.md
PDIR=~/.config/omarchy/plugins/$ID

is_thinkpad || suite_skip "not a ThinkPad"
[ -d "$PDIR" ] || suite_skip "the plugin is not installed (this test removes it and puts it back)"
[ "$(plugin_state)" = enabled ] || suite_skip "the plugin is not enabled in the bar"
CLI=$PDIR/bin/omarchyfan; [ -x "$CLI" ] || CLI=$PDIR/bin/omarchy-fan
[ "$(setup_state)" = ready ] || suite_skip "fan control is not set up (setup state: $(setup_state))"
sudo -n true 2>/dev/null || suite_skip "needs passwordless sudo"
command -v yay >/dev/null || suite_skip "needs yay (the installer builds thinkfan from the AUR)"
[ -e "$ROOT/.git" ] || suite_skip "needs a git checkout to install from"
temp0=$(cpu_temp)
[ "${temp0:-99}" -le 48 ] || suite_skip "the CPU is warm (${temp0}C): the fan is left alone for minutes, run this on an idle laptop"

orig=$("$CLI" current)
orphans0=$(pacman -Qdtq 2>/dev/null | sort)    # orphans that are already on the system are not ours
manual=$(cat ~/.config/omarchy/fan/manual-level 2>/dev/null || echo 3)
nofollow=$([ -e ~/.config/omarchy/fan/no-follow ] && echo yes || echo no)
index=$(jq -r --arg id "$ID" '[.. | objects | select(has("right")) | .right | map(.id)][0] | index($id) // empty' ~/.config/omarchy/shell.json 2>/dev/null)

restore() {
  trap - EXIT
  echo "-- putting the plugin back"
  [ -d "$PDIR" ] || omarchy plugin add "file://$ROOT" --enable --yes >/dev/null 2>&1
  ( cd "$PDIR" && yes | bash install-helper.sh >/dev/null 2>&1 )
  [ -n "$index" ] && omarchy bar move "$ID" --section right --index "$index" >/dev/null 2>&1
  [ "$nofollow" = yes ] && "$PDIR/bin/omarchyfan" follow off >/dev/null 2>&1
  case "$orig" in manual) "$PDIR/bin/omarchyfan" manual "$manual" ;; *) "$PDIR/bin/omarchyfan" "$orig" ;; esac >/dev/null 2>&1
  echo "   back: plugin $(plugin_state), setup $("$PDIR/bin/omarchyfan" stats 2>/dev/null | awk -F'\t' '$1=="setup"{print $2}'), profile $("$PDIR/bin/omarchyfan" current 2>/dev/null)"
  rm -rf "$ROOT"   # the scratch copy this run was working from
}
trap restore EXIT

echo "-- the README's Uninstall block, as written"
block=$(awk '/^## Uninstall/{on=1;next} /^## /{on=0} on && /^    [^ ]/{sub(/^    /,""); print}' "$README")
t "the README has an Uninstall block with commands" "$([ "$(echo "$block" | wc -l)" -ge 5 ] && echo yes || echo no)" yes
# only changes needed to run unattended: sudo without a prompt, pacman and the plugin remove without a question
script=$(mktemp)
echo "$block" | sed -e 's/\bsudo /sudo -n /g' -e 's/pacman -Rns/pacman -Rns --noconfirm/' \
  -e 's#\(omarchy plugin remove [^ ]*\)#\1 --yes#' > "$script"
echo "$block" | sed 's/^/   $ /'
bash "$script" > /tmp/omarchyfan-uninstall.$$.log 2>&1; rc=$?
t "every command in the block succeeds" "$rc" 0
[ "$rc" = 0 ] || sed 's/^/   | /' /tmp/omarchyfan-uninstall.$$.log
rm -f "$script" /tmp/omarchyfan-uninstall.$$.log

echo "-- nothing of the plugin is left"
absent() { # <what> <command that prints something only when it is still there>
  local out; out=$(eval "$2" 2>/dev/null)
  t "$1" "${out:-none}" none
}
absent "the plugin folder is gone"                   "ls -d $PDIR"
absent "the plugin is not in 'omarchy plugin list'"  "omarchy plugin list | grep -i thinkpad-fan"
absent "the bar layout no longer mentions it"        "grep -o $ID ~/.config/omarchy/shell.json"
absent "no command or man-page links"                "ls ~/.local/bin/omarchyfan ~/.local/bin/omarchy-fan ~/.local/share/man/man1/omarchyfan.1 ~/.local/share/man/man1/omarchy-fan.1"
absent "no saved state in ~/.config/omarchy/fan"     "ls -d ~/.config/omarchy/fan"
absent "the follower is not running"                 "pgrep -f '^/usr/bin/bash [^ ]*/bin/omarchy-fan-follow\$'"
absent "no omarchy-fan-helper package"               "pacman -Q omarchy-fan-helper"
absent "no thinkfan package"                         "pacman -Q thinkfan"
absent "no thinkfan-debug package"                   "pacman -Q thinkfan-debug"
absent "no orphaned dependency of thinkfan (yaml-cpp)" "pacman -Qq yaml-cpp"
absent "no new orphaned packages (ones from before don't count)" "comm -13 <(echo '$orphans0') <(pacman -Qdtq | sort)"
absent "no helper, curves, polkit policy, modprobe or systemd files" \
  "ls -d /usr/lib/omarchy-fan /usr/share/omarchy-fan /usr/share/polkit-1/actions/org.omarchy.fan.policy /usr/lib/modprobe.d/omarchy-fan.conf /usr/lib/systemd/system/thinkfan.service.d /usr/share/licenses/omarchy-fan-helper"
absent "no /etc/thinkfan.yaml (the curve we wrote)"  "ls /etc/thinkfan.yaml"
absent "no yay build cache for thinkfan"             "ls -d ~/.cache/yay/thinkfan"
t "thinkfan is not running"  "$(systemctl is-active thinkfan 2>&1)" inactive
t "thinkfan is not enabled"  "$(systemctl is-enabled thinkfan 2>&1 | head -1)" not-found
t "the fan is back with the firmware (or about to be: its watchdog fires within 2 minutes)" \
  "$(fan_level | grep -E '^(auto|[0-9]+|disengaged)$' >/dev/null && echo yes || echo no)" yes
echo "-- anything else on the system with our name (excluding your work folders and the package cache)"
rest=$(find / -xdev \( -path /proc -o -path /sys -o -path /var/lib/pacman -o -path /var/cache/pacman -o -path "$HOME/.claude" -o -path "$HOME/Work" -o -path /tmp -o -path "/run/user" \) -prune \
  -o \( -iname '*omarchy-fan*' -o -iname '*omarchyfan*' -o -iname 'thinkfan*' -o -path '*thinkpad-fan*' \) -print 2>/dev/null | grep -v "^$HOME/.config/omarchy/shell.json")
t "nothing else named omarchy-fan, omarchyfan, thinkfan or thinkpad-fan" "${rest:-none}" none
[ -n "$rest" ] && echo "$rest" | sed 's/^/   left: /'
info "the follower's empty lock file in /run/user/$UID is on tmpfs and goes away when you log out"

finish
