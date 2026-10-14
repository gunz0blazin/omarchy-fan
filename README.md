# ThinkPad Fan Control for Omarchy

A bar widget for [Omarchy](https://omarchy.org) that controls a ThinkPad's fan. Click the fan icon and you get a
panel in the same style as the wifi and bluetooth ones:

- live fan RPM and a two-minute history graph
- three curve profiles: **Quiet**, **Balanced**, **Performance** (a smooth thinkfan curve with hysteresis)
- a **manual slider**: off, levels 1 to 7, or full speed
- a **Follow power profile** switch: with it on, switching the power profile (power-saver, balanced, performance)
  switches the fan profile too; with it off your fan setting stays until you change it

It follows your theme (colors, fonts, panel style) because it is built from the same Omarchy UI components as the
built-in panels. There is also a CLI: `omarchy-fan quiet|balanced|performance|manual <0-8>|follow on|off|status`.

<!-- screenshot -->
![the fan panel](docs/panel.png)

## Requirements

- A ThinkPad using the `thinkpad_acpi` driver (written and tested on a T480s; any ThinkPad with `/proc/acpi/ibm/fan`
  should work). On other laptops the widget hides itself.
- Omarchy with the shell plugin system (`omarchy plugin ...`), `power-profiles-daemon` (the Omarchy default).
- `thinkfan` (AUR) and a small root helper package, both installed for you, see below.

## Install

    omarchy plugin add https://github.com/gunz0blazin/omarchy-fan --enable

Then open the fan icon in the bar. Because changing the fan needs root, the panel shows an **Install fan control**
button the first time. It opens a terminal that runs `install-helper.sh`, which installs `thinkfan` from the AUR
(through `omarchy-pkg-aur-add`), builds the small `omarchy-fan-helper` package from `packaging/PKGBUILD`, installs it
with `makepkg -si` (you confirm it and type your sudo password there), and turns fan control on. You can run it
yourself instead: `~/.config/omarchy/plugins/isaiah.fan/install-helper.sh`.

If you want a different spot in the bar, `omarchy plugin enable isaiah.fan` asks where.

## How it works, and what it changes on your system

The plugin has two halves.

**The plugin (runs as you):** `Panel.qml` draws the widget, `bin/omarchy-fan` is the CLI the panel calls,
and `bin/omarchy-fan-follow` (started by the panel, stops when the shell does) watches `power-profiles-daemon` over
D-Bus. Your choices live in `~/.config/omarchy/fan/` (the active profile, the manual level, the follow flag).

**The root helper (the `omarchy-fan-helper` package):** installs these files and nothing else:

| File | What it is |
|---|---|
| `/usr/lib/omarchy-fan/helper` | The only thing that runs as root. It takes `set quiet\|balanced\|performance`, `set manual 0-8` or `enable`, and rejects anything else. It never takes a path or a config from the user: it builds `/etc/thinkfan.yaml` from the root-owned profiles below. |
| `/usr/share/omarchy-fan/profiles/*.yaml` | The three thinkfan curves. |
| `/usr/share/polkit-1/actions/org.omarchy.fan.policy` | Lets a user in a local, active session run that one helper without a password, the way brightness works. |
| `/usr/lib/modprobe.d/omarchy-fan.conf` | `options thinkpad_acpi fan_control=1`, which thinkfan needs. |
| `/usr/lib/systemd/system/thinkfan.service.d/omarchy-fan.conf` | Turns off systemd's start rate limit, because moving the slider restarts thinkfan. |

Everything is a normal pacman package, so `pacman -Qlp`, `pacman -Ql omarchy-fan-helper` and `pacman -Rns` work as you'd
expect. The curves use the ThinkPad's own embedded-controller temperature (`/proc/acpi/ibm/thermal`), not a
CPU-vendor sensor, so Intel and AMD ThinkPads are treated the same.

If thinkfan stops or the plugin is removed, the firmware takes the fan back. The fan is always at full speed well
before the CPU's critical temperature.

## Uninstall

    omarchy plugin remove isaiah.fan
    sudo pacman -Rns omarchy-fan-helper       # optional: removes the helper, policy and curves
    sudo systemctl disable --now thinkfan     # optional: give the fan back to the firmware

## Change the curves

The curves are thinkfan YAML files, the three in [`profiles/`](profiles/). The helper reads the installed copies in
`/usr/share/omarchy-fan/profiles/`, so edit those (or fork this repo, change `profiles/`, and rebuild the package with
`cd packaging && makepkg -si`). Each row is `[fan level, lower temperature, upper temperature]`.

## Troubleshooting

- **The icon isn't in the bar:** it only shows on a ThinkPad. Check `ls /proc/acpi/ibm/fan`.
- **The panel says "Enable fan control":** the helper is installed but thinkfan isn't running or `fan_control` is off.
  Press the button, or `pkexec /usr/lib/omarchy-fan/helper enable`.
- **The slider doesn't hold or the fan resets:** turn off "Follow power profile". Changing the power profile (including
  Omarchy changing it when you plug in) resets the fan while that switch is on.
- **`fan_control` still reads N after setup:** `cat /sys/module/thinkpad_acpi/parameters/fan_control`. If the module
  couldn't be reloaded, reboot once.

## Tests

    tests/check.sh           # manifest, shell syntax, QML lint (no hardware needed)
    tests/test-helper.sh     # on a ThinkPad with the helper installed: curves, manual levels, restart storm, bad input

## Credits and license

MIT, see [LICENSE](LICENSE). The panel layout follows the built-in Omarchy panels (MIT) so it matches them.
thinkfan is by Evgeni Golov and contributors.
