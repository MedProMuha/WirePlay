#!/usr/bin/env python3
"""Run real replacement logic against temporary dummy app bundles.

Signature checks and app shutdown are mocked: this verifies transaction ordering
and recovery, not whether dummy bundles are signed. No system app is modified.
"""
from pathlib import Path
import shlex
import subprocess
import tempfile

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
STUBS = r'''
source "$INSTALLER"
ditto() {
  echo copy >> "$EVENTS"
  [[ "$CASE" != copy_failure ]] || return 99
  /bin/cp -R "$3" "$4"
}
wireplay_verify_app() {
  echo "verify:$1" >> "$EVENTS"
  [[ "$CASE" != staged_verification_failure ]] || return 99
  if [[ "$1" == "$DEST" && ( "$CASE" == final_verification_failure || "$CASE" == rollback_failure || "$CASE" == evacuation_failure ) ]]; then
    return 99
  fi
  [[ -f "$1/new-marker" ]]
}
wireplay_quit_running() {
  echo quit >> "$EVENTS"
  [[ "$CASE" != quit_refused ]]
}
mv() {
  if [[ "$CASE" == promotion_failure && "$1" == "$WORK/WirePlay.app" ]]; then return 99; fi
  if [[ "$CASE" == rollback_failure && "$1" == "$BACKUP" ]]; then return 99; fi
  if [[ "$CASE" == evacuation_failure && "$2" == "$WORK/rejected-WirePlay.app" ]]; then return 99; fi
  /bin/mv "$@"
}
wireplay_replace_app "$APP" "$DEST"
'''


def replacement_case(case):
    with tempfile.TemporaryDirectory(prefix="wireplay-install-check-") as directory:
        root = Path(directory)
        app, dest, events = root / "new.app", root / "installed.app", root / "events"
        app.mkdir()
        dest.mkdir()
        (app / "new-marker").write_text("new")
        (dest / "old-marker").write_text("old")
        result = subprocess.run(
            ["/bin/bash", "-c", STUBS],
            env={"PATH": "/usr/bin:/bin", "INSTALLER": str(INSTALLER),
                 "APP": str(app), "DEST": str(dest), "EVENTS": str(events), "CASE": case},
            text=True, capture_output=True, timeout=10,
        )
        assert (result.returncode == 0) == (case == "success"), (case, result)
        old = list(root.rglob("old-marker"))
        assert len(old) == 1, (case, "previous app lost or duplicated", old)
        if case in ("success", "rollback_failure", "evacuation_failure"):
            assert old[0].parent.name == "previous-WirePlay.app", (case, old)
            assert str(old[0].parent) in result.stdout, (case, "backup location not reported")
        else:
            assert old[0] == dest / "old-marker", (case, "previous app not restored")
        assert (dest / "new-marker").exists() == (case in ("success", "evacuation_failure")), case
        calls = events.read_text().splitlines()
        if case in ("copy_failure", "staged_verification_failure"):
            assert "quit" not in calls, (case, "app quit before staging verified")
        else:
            assert calls[0] == "copy" and calls[1].startswith("verify:") and calls[2] == "quit", calls
        if case == "success":
            assert calls[-1] == f"verify:{dest}", "installed app not checked"
        print(f"PASS {case}: previous app preserved; exit={result.returncode}")


for case in ("success", "copy_failure", "staged_verification_failure", "quit_refused",
             "promotion_failure", "final_verification_failure", "rollback_failure", "evacuation_failure"):
    replacement_case(case)

# Exercise the real download entry point with a stub release response. The script
# must reject a missing/wrong checksum before a download or any install action.
for case in ("missing_checksum", "unrelated_checksum"):
    with tempfile.TemporaryDirectory(prefix="wireplay-checksum-check-") as directory:
        root = Path(directory)
        (root / "sw_vers").write_text("#!/bin/sh\necho 26.0\n")
        url = "https://example.invalid/WirePlay.zip"
        assets = '{"browser_download_url": "' + url + '"}'
        if case == "unrelated_checksum":
            assets += '\n{"browser_download_url": "https://example.invalid/Other.zip.sha256"}'
        (root / "release").write_text(assets)
        (root / "curl").write_text(
            "#!/bin/sh\ncase \"$*\" in\n*releases/latest*) /bin/cat "
            + shlex.quote(str(root / "release"))
            + ";;\n*) echo unexpected-network-call >&2; exit 99;;\nesac\n"
        )
        for executable in ("sw_vers", "curl"):
            (root / executable).chmod(0o755)
        result = subprocess.run(
            ["/bin/bash", str(INSTALLER)],
            env={"PATH": str(root) + ":/usr/bin:/bin", "HOME": str(root)},
            text=True, capture_output=True, timeout=10,
        )
        assert result.returncode != 0 and "matching checksum" in result.stdout, (case, result)
        assert "unexpected-network-call" not in result.stderr, (case, result)
        print(f"PASS {case}: rejected before download or installation")

assert '/bin/bash ./install.sh --local "$APP"' in (INSTALLER.parent / "build.sh").read_text()
print("10 installer safety checks passed; build.sh uses the checked replacement path.")
