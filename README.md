# ThinkPad Fan Control for Omarchy

Control your ThinkPad's fan from the Omarchy bar. One icon opens a panel styled like the built-in wifi and bluetooth
panels, and it follows your theme.

![the fan panel](docs/panel.png)

- **Live fan RPM** and a two-minute history graph
- **Three curve profiles**: Quiet, Balanced and Performance, smooth [thinkfan](https://github.com/vmatare/thinkfan)
  curves with hysteresis, so the fan doesn't flutter
- **A manual slider**: off, levels 1 to 7, or full speed
- **Follow power profile**: switch the power profile and the fan profile follows (power-saver is Quiet, balanced is
  Balanced, performance is Performance). Turn it off and your fan setting stays put until you change it

## Quick start

    omarchy plugin add https://github.com/gunz0blazin/omarchy-fan --enable

`omarchy plugin add` shows the usual "plugins run unsandboxed" warning and asks which part of the bar to put the icon
in. Then:

1. Click the fan icon. The first time, the panel shows **Install fan control**.
2. It opens a terminal that installs `thinkfan`, builds a small helper package and installs it (you confirm the
   package and enter your sudo password there), and turns fan control on.
3. Done: the panel now shows live RPM and the controls.

Prefer to do step 2 yourself? Run `install-helper.sh` from the plugin folder
(`~/.config/omarchy/plugins/io.github.gunz0blazin.thinkpad-fan/`).

## Compatibility

| | |
|---|---|
| **Tested on** | ThinkPad T480s (Intel), Omarchy with the shell plugin system |
| **Should work on** | Any ThinkPad that exposes `/proc/acpi/ibm/fan` through `thinkpad_acpi`, Intel or AMD. The curves read the ThinkPad's own embedded-controller temperature, not a CPU-vendor sensor. Not tried on other models yet, reports welcome |
| **Other laptops** | The widget hides itself when there is no `thinkpad_acpi` |
| **Needs** | `power-profiles-daemon` (Omarchy default), `polkit`, `thinkfan` (AUR) |

## The profiles

Temperatures are the ThinkPad's CPU sensor reading.

| Profile | Fan leaves "off" at | Fan is at full speed above | Feel |
|---|---|---|---|
| Quiet | about 65°C | about 92°C | Silent longest, runs warmest |
| Balanced | about 56°C | about 85°C | Smooth curve, the default |
| Performance | never off (level 1 minimum) | about 74°C | Cooler, spins up early |

These are the files in [`profiles/`](profiles/), one row per fan level as `[level, lower temp, upper temp]`. Manual
mode pins a single level instead of following a curve.

## CLI

The panel calls the same script you can use from a terminal:

    omarchy-fan quiet|balanced|performance      # pick a curve
    omarchy-fan manual 0-8                      # 0 is off, 8 is full speed
    omarchy-fan follow on|off                   # follow the power profile or not
    omarchy-fan status

It lives in `bin/`; put it on your PATH with
`ln -s ~/.config/omarchy/plugins/io.github.gunz0blazin.thinkpad-fan/bin/omarchy-fan ~/.local/bin/`.

## What it installs, and why

Changing the fan needs root, so the plugin is split in two.

**The plugin runs as you.** `Panel.qml` draws the widget, `bin/omarchy-fan` is the CLI the panel calls, and
`bin/omarchy-fan-follow` (started by the panel, stopped when the shell stops) listens for power-profile changes over
D-Bus. Your choices live in `~/.config/omarchy/fan/`.

**A small root helper, as a normal pacman package** (`omarchy-fan-helper`, built from
[`packaging/PKGBUILD`](packaging/PKGBUILD) on your machine). It installs exactly these files:

| File | What it is |
|---|---|
| `/usr/lib/omarchy-fan/helper` | The only thing that runs as root. It accepts `set quiet\|balanced\|performance`, `set manual 0-8`, `enable`, or `ensure-module` (run by thinkfan's service, see below), and rejects everything else. It never takes a path or config from the caller: it builds `/etc/thinkfan.yaml` from the root-owned profiles below |
| `/usr/share/omarchy-fan/profiles/*.yaml` | The three curves |
| `/usr/share/polkit-1/actions/org.omarchy.fan.policy` | Lets a user in a local, active session run that one helper without a password, the way screen brightness works. There is no sudoers rule |
| `/usr/lib/modprobe.d/omarchy-fan.conf` | `options thinkpad_acpi fan_control=1`, which thinkfan needs whenever the driver is loaded normally |
| `/usr/lib/systemd/system/thinkfan.service.d/omarchy-fan.conf` | Turns off systemd's start rate limit (moving the slider restarts thinkfan), and runs the helper's `ensure-module` just before thinkfan starts: at boot the driver is usually loaded early, from the initramfs, without `fan_control=1`, and thinkfan refuses to start until it is reloaded with it. A failure there never stops thinkfan from starting |

Worth knowing:

- `install-helper.sh` installs `thinkfan` with `omarchy-pkg-aur-add`, which uses `yay --noconfirm` and so **skips the
  PKGBUILD review prompt**. If you want to read it first, install thinkfan yourself (`yay -S thinkfan`) before you
  press the button, and the script will skip that step.
- If you already have your own `/etc/thinkfan.yaml`, the helper saves the first copy as
  `/etc/thinkfan.yaml.omarchy-fan.bak` before it writes a profile. Installing the helper alone never replaces it.
  Restore with `sudo cp /etc/thinkfan.yaml.omarchy-fan.bak /etc/thinkfan.yaml`.
- Everything is a plain package: `pacman -Ql omarchy-fan-helper` lists it, `pacman -Rns omarchy-fan-helper` removes it.
- With thinkfan running, the ThinkPad's firmware still has its own thermal protection, and every profile reaches full
  speed well below the CPU's critical temperature.

## Uninstall

    omarchy plugin remove io.github.gunz0blazin.thinkpad-fan
    sudo systemctl disable --now thinkfan        # gives the fan back to the firmware
    sudo pacman -Rns omarchy-fan-helper          # removes the helper, polkit policy and curves

Removing the plugin alone does **not** stop thinkfan: the fan keeps running on the last curve you chose until you
disable the service.

## Customising the curves

The helper reads the installed copies in `/usr/share/omarchy-fan/profiles/`. Edit those, or fork this repo, change
`profiles/`, and rebuild with `cd packaging && makepkg -si`.

## Troubleshooting

- **No icon in the bar:** it only appears on a ThinkPad. Check `ls /proc/acpi/ibm/fan`. If it's there but the icon
  isn't, make sure the plugin is in a bar section: it goes in the center by default, and you can move its id in
  `~/.config/omarchy/shell.json` (`bar.layout`).
- **Panel says "Enable fan control":** the helper is installed but thinkfan isn't running, or `fan_control` is off.
  Press the button, or run `pkexec /usr/lib/omarchy-fan/helper enable`.
- **The fan setting keeps resetting:** turn off "Follow power profile". Any power profile change, from any source,
  resets the fan while it's on.
- **`fan_control` still says N:** check `cat /sys/module/thinkpad_acpi/parameters/fan_control`. If the module couldn't
  be reloaded, reboot once.
- **A reading of 65535 RPM:** the controller reports that for a moment while the fan changes speed. The plugin ignores
  it.

## Development and tests

    tests/check.sh           # manifest validation, shell syntax, QML lint (no hardware needed)
    tests/test-helper.sh     # ThinkPad + helper installed: curves, manual levels, a restart storm, rejected input
    tests/test-follow.sh     # the plugin running in the bar: power-profile following, follow on/off

The last two change your fan and power profile while they run and put both back afterwards.

## Credits and license

MIT, see [LICENSE](LICENSE). The panel is built from the stock Omarchy UI components so it matches the built-in panels.
Fan curves are driven by [thinkfan](https://github.com/vmatare/thinkfan).
