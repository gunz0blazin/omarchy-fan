# Developing ThinkPad Fan Control

This page is for people who work on the code or run the test suite. To use the plugin, the [README](README.md) is all you
need. To report a new ThinkPad model, see [Report a new ThinkPad model](README.md#report-a-new-thinkpad-model).

## How work flows

- Work happens on the `dev` branch. Open pull requests against `dev`.
- `main` is what `omarchy plugin add` installs. The maintainer merges `dev` into `main` now and then, after a lot of
  `dev` work and a full test run.
- Tests are run by hand, when you choose: there are no git hooks and nothing runs automatically.
- Nothing in the test stack loads or heats the CPU, suspends the laptop or locks the screen.

## The test stack in one command

`tests/full-test.sh` is the one runner. It picks the suites for a level, runs them in the right order, prints a pass/fail
table and exits non-zero if anything failed. There are four levels; each one includes the one before it:

    bash tests/full-test.sh              # commit: the small check, for every commit (about 10 seconds, read-only)
    bash tests/full-test.sh --quick      # commit + the package and CLI-link suites (about 35 seconds, still read-only)
    bash tests/full-test.sh --base       # quick + the device suites: before merging to main (about 3.5 minutes, budget 4)
    bash tests/full-test.sh --release    # base + a clean uninstall/reinstall + the marketplace scanner: before merging to main (about 4.5 minutes)

| Level | Suites | Time | Needs | Use it |
|---|---|---|---|---|
| **commit** | `check`, `marketplace`, `readme`, `compat` | ~10 s | nothing (any machine) | every commit: the code parses and runs against fake machines, the manifest and marketplace rules hold, the docs still match the code |
| **quick** | commit + `package`, `cli-link` | ~35 s | `makepkg` | when you touch packaging or the command links |
| **base** | quick + `panel`, `follow`, `helper`, `effect`, `safety-net`, `safety-reload`, `safety-handoff` | ~3.5 min | the ThinkPad, the plugin in the bar, `sudo` | before merging to `main`: the plugin works on the device, the fan obeys, the safety rows are there, the firmware takes over when the plugin goes |
| **release** | base + `uninstall`, `scan` | ~4.5 min | as base, plus network, `node` and a pushed commit | before merging to `main`: a clean uninstall leaves nothing behind, and the marketplace's own security scanner passes on the pushed commit |

The small check (`commit`) is the everyday one. `--base` and `--release` are the big checks, run before a merge to
`main`: they change the fan, restart the shell and need `sudo`.

### Options

    bash tests/full-test.sh --list               # every suite: its level, measured time, what it needs, what it proves
    bash tests/full-test.sh --only readme,check  # just these suites (ids from --list), whatever their level
    bash tests/full-test.sh --sync [REF]         # first put the installed plugin and helper on origin/REF (default dev)

- `--sync` makes the device run exactly what was pushed: it switches the installed plugin's clone to `origin/REF`,
  rebuilds and installs the helper package if the helper or the curves differ (needs `sudo`), and restarts the shell.
  Without it, the device suites test whatever plugin is installed, and the banner warns when that differs from your checkout.
- `--only` takes suite ids, not script names: `bash tests/full-test.sh --only safety-net,safety-handoff`.
- `--list` also prints a wall-clock estimate for each level.

### Exit status

- `full-test.sh`: `0` when nothing failed (skips are allowed), `1` when a suite failed or ran past its time limit, `2` for an
  unknown option or when nothing was selected.
- Each test script: `0` when all its checks passed, `1` when one failed, `77` when it cannot run on this machine (not a
  ThinkPad, no `sudo`, no plugin in the bar...), with the reason printed. `full-test.sh` shows a `77` as skipped.
- Every script prints `passed`, `failed` and `skipped` counts, so a skipped check can't pass for a real one.

### One fan, one at a time

The read-only suites (`commit` and `quick` levels) run in parallel. The device suites run one after the other, because
they share the one fan, the one shell and the one installed plugin. **Never run two device suites, or two `full-test.sh
--base`/`--release` runs, at the same time** (not from two terminals, not from two sessions): they would change the fan under
each other and both results would be wrong.

## What every suite proves

The registry at the top of `tests/full-test.sh` (`REGISTRY`) is the one place that decides which suite runs at which
level, how long it may take and what it needs. Every script also runs on its own: `bash tests/<name>.sh`.

| Suite id | Script | Level | Needs | What it proves |
|---|---|---|---|---|
| `check` | `tests/check.sh` | commit | - | manifest validation, shell syntax and executable bits, man-page lint, the curve files' shape, the profile safety rule (full speed by 86C), the helper package version is raised whenever what it installs changes, QML lint |
| `marketplace` | `tests/check-marketplace.sh` | commit | - | the marketplace publishing and development rules: manifest fields, id rules, README sections and disclosures, symlinks, the security-baseline patterns |
| `readme` | `tests/test-readme.sh` | commit | `python3` | the README, this page and the man page against the code: documented subcommands exist, documented paths are real, the profile-table numbers match the curve files, every test script is listed here, links resolve |
| `compat` | `tests/test-compat.sh` | commit | - | `omarchyfan doctor` and `stats` against fake `/proc` and `/sys` trees in `tests/fixtures/`: the tested T480s, other ThinkPad shapes, second fans (controlled, not controllable, control lost, mirrored), `fan_control` off, a 65535 speed glitch, missing files and a non-ThinkPad. To add a model, see `tests/fixtures/README.md` |
| `package` | `tests/test-package.sh` | quick | `makepkg` | builds the root-helper package in a scratch folder and checks exactly what it installs: files, owners, modes, the polkit policy, no sudoers rule. Nothing is installed |
| `cli-link` | `tests/test-cli-link.sh` | quick | - | the command and man-page links the plugin makes, in a fake home, including the legacy `omarchy-fan` name; the follower leaves no stray `dbus-monitor` behind (clean stop, hard kill, or an orphan left by an old one) |
| `panel` | `tests/test-panel.sh` | base | the plugin in the bar | the panel opens and closes (also with Escape and toggle), the shell log shows no plugin errors, and the plugin survives a disable and re-enable with its icon back in place. `SKIP_CYCLE=1` skips the disable/enable part |
| `follow` | `tests/test-follow.sh` | base | the plugin in the bar | the power-profile follower reacts, stays a single process and leaves AC alone. Don't plug or unplug the charger while it runs |
| `helper` | `tests/test-helper.sh` | base | helper, thinkfan | each curve applies, manual levels reach the kernel, nine rapid restarts don't break thinkfan, an outdated helper is noticed, `reapply` rewrites a stale config, and the root helper rejects bad input without changing anything |
| `effect` | `tests/test-effect.sh` | base | helper, thinkfan | the fan really speeds up, slows down and stops (RPM, not just the requested level). Run it on an idle laptop; the fan gets loud for a few seconds |
| `safety-net` | `tests/test-safety.sh` (`PARTS=net`) | base | `sudo` | every pinned manual level 0-7 gets a full-speed safety row at 80C and up; level 8 is a single full-speed row |
| `safety-reload` | `tests/test-safety.sh` (`PARTS=reload`) | base | `sudo` | reloading the `thinkpad_acpi` driver (the boot hook does) leaves the LEDs, battery limits, hotkeys, input devices and radios as they were, and the fan still answers |
| `safety-handoff` | `tests/test-safety.sh` (`PARTS=handoff`) | base | `sudo` | when thinkfan stops or is disabled (what removing the plugin does), the firmware takes the fan back within 10 s |
| `uninstall` | `tests/test-uninstall.sh` | release | `sudo`, network | runs the README's uninstall one-liner (and checks the Uninstall command sits right after Install), then checks nothing of the plugin is left (packages, files, links, saved state, services, the bar entry), and installs the plugin again |
| `scan` | `tests/check-marketplace.sh` (`MARKETPLACE_SCAN=1`) | release | network, `node`, a pushed commit | the marketplace's own security scanner on the pushed commit: no findings, no capability beyond the ones already accepted |

`tests/full-test.sh` is the runner, not a test. `tests/lib.sh` holds the shared helpers (`t`, `ok`, `bad`, `skip`, the fan
readers). `tests/test-safety.sh` runs all three parts by itself, or some with `PARTS="net handoff" bash tests/test-safety.sh`.

### By what they touch

If you run scripts by hand, this is how much each one may touch:

| Tier | What it may touch | Scripts |
|---|---|---|
| **static** | reads files only | `tests/check.sh`, `tests/check-marketplace.sh`, `tests/test-readme.sh`, `tests/test-package.sh`, `tests/test-compat.sh` |
| **local** | a throwaway home directory | `tests/test-cli-link.sh` |
| **shell** | briefly uses, and for one test disables and re-enables, the plugin in your running bar | `tests/test-panel.sh`, `tests/test-follow.sh` |
| **hardware** | changes your fan profile (and, for the follower test, your power profile), then restores them | `tests/test-helper.sh`, `tests/test-effect.sh` |
| **destructive** | needs `sudo`; stops thinkfan or reloads the driver for a few seconds, or removes the plugin and puts it back | `tests/test-safety.sh`, `tests/test-uninstall.sh` |

The scripts also work on older versions of the repo (they find the command under either name), which is how a release
can be compared with the one before it.

## Adding a suite

1. Write `tests/<name>.sh`: source `tests/lib.sh`, use `t`/`ok`/`bad`/`skip`, end with `finish`, and `suite_skip "why"`
   (exit 77) when the machine can't run it.
2. Add one line to `REGISTRY` in `tests/full-test.sh`: id, script, env, level, measured seconds, time limit, needs, and
   what it proves. `full-test.sh` warns about any script that is not in the registry.
3. List it in the tables on this page (`tests/test-readme.sh` fails until it is).
4. Keep `--base` under its 4-minute budget, and keep anything that loads the CPU, suspends or locks the screen out of the stack.
