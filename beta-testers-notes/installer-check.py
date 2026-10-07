#!/usr/bin/env python3
"""Reproduce installer failure paths using only temporary dummy app directories.

No installer is run. Only the exact replacement block of each installer is
extracted; failing cp/mv operations are injected as shell functions.
"""
from pathlib import Path
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent.parent
build = (SOURCE / "build.sh").read_text()
installer = (SOURCE / "install.sh").read_text()
copy_block = next(line for line in build.splitlines()
                  if 'rm -rf "$DEST" && cp -R "$APP" "$DEST"' in line)
swap_block = installer.split('BACKUP=""\n', 1)[1].split(
    "\n# The app is open source", 1)[0]
swap_block = 'BACKUP=""\n' + swap_block
cleanup = next(line for line in installer.splitlines() if line.startswith("trap "))
# Refuse to run if extraction starts including actual application/system actions.
assert all(word not in copy_block + swap_block + cleanup
           for word in ("/Applications", "pkill", "xattr", "open ", "lsregister", "pluginkit"))


def run_case(name, shell, script, expected_old, expected_new):
    with tempfile.TemporaryDirectory(prefix="wireplay-installer-check-") as directory:
        root = Path(directory)
        dest, staging = root / "installed.app", root / "staging"
        new = staging / "new.app"
        dest.mkdir()
        new.mkdir(parents=True)
        (dest / "old-marker").write_text("old app")
        (new / "new-marker").write_text("new app")
        result = subprocess.run(
            [shell, "-c", "set -euo pipefail\n" + script],
            env={"PATH": "/usr/bin:/bin", "DEST": str(dest), "TMP": str(staging),
                 "APP": str(new), "NEW_APP": str(new)},
            capture_output=True, text=True, timeout=10,
        )
        old_exists = any(root.rglob("old-marker"))
        new_installed = (dest / "new-marker").exists()
        assert result.returncode != 0, (name, result)
        assert old_exists == expected_old, (name, old_exists)
        assert new_installed == expected_new, (name, new_installed)
        if expected_old:
            assert (dest / "old-marker").exists(), "Recovery did not restore destination"
        print(f"CONFIRMED {name}: exit={result.returncode}, "
              f"old_app_preserved={old_exists}, new_app_installed={new_installed}")


run_case("build.sh copy failure loses existing app", "/bin/zsh",
         "cp() { return 99; }\n" + copy_block, False, False)

run_case("install.sh successful rollback preserves existing app", "/bin/bash",
         cleanup + "\n" + '''mv() {
  if [[ "$1" == "$NEW_APP" ]]; then return 99; fi
  /bin/mv "$@"
}
''' + swap_block, True, False)

run_case("install.sh failed rollback cleanup loses backup", "/bin/bash",
         cleanup + "\n" + '''mv() {
  if [[ "$1" == "$NEW_APP" || "$1" == "$TMP/previous-WirePlay.app" ]]; then return 99; fi
  /bin/mv "$@"
}
''' + swap_block, False, False)
