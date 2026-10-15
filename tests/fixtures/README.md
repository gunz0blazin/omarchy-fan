# Fixtures

Each folder is a copy of the parts of `/proc` and `/sys` that `omarchyfan` reads. `tests/test-compat.sh` points
`OMARCHYFAN_ROOT` at one and checks what `omarchyfan doctor` and `omarchyfan stats` say.

- `t480s` is a real capture from the tested machine.
- The rest are hand-made edge cases (a second fan: kernel-controlled, not controllable, readable only, control lost after boot, or mirroring the first; an off `fan_control`, a transient 65535 speed, a missing file, a
  non-ThinkPad). They show what the plugin does on such hardware; they are not captures of those exact models.

To add a real machine: run `omarchyfan doctor` on it, copy `/proc/acpi/ibm/{fan,thermal}`, the files under
`/sys/class/dmi/id/` that `doctor` prints, and `/sys/module/thinkpad_acpi/parameters/fan_control`, here, and add its
expected result to `tests/test-compat.sh`.

Git does not keep empty folders, so the empty `sys/devices/platform/thinkpad_acpi` folders hold a `.gitkeep` file.
Without it the fixture would be missing after a `git clone` and the tests would see a machine with no driver.
A fixture's `kernel.log` stands in for the kernel messages (`journalctl -k`) that `doctor` checks for secondary fan control.
