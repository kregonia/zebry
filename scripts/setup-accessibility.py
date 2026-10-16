#!/usr/bin/env python3
"""Configure per-user Linux accessibility bridges and Chromium startup flags.

This is an explicit setup utility, never invoked by zebry or the build.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

VARIABLES = {
    "ACCESSIBILITY_ENABLED": "1",
    "GNOME_ACCESSIBILITY": "1",
    "QT_ACCESSIBILITY": "1",
    "QT_LINUX_ACCESSIBILITY_ALWAYS_ON": "1",
}
FLAG = "--force-renderer-accessibility"
MARKER = "# Managed by zebry setup-accessibility.py"
KDL_MARKER = "// Managed by zebry setup-accessibility.py"


def command(args, **kwargs):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10, **kwargs)
    except (OSError, subprocess.TimeoutExpired):
        return None


def session_snapshot():
    result = command(["systemctl", "--user", "show-environment"])
    environment = None
    if result is not None and result.returncode == 0:
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        environment = {key: values.get(key) for key in VARIABLES}
    result = command(["busctl", "--user", "get-property", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled"])
    enabled = None
    if result is not None and result.returncode == 0 and result.stdout.strip() in ("b true", "b false"):
        enabled = result.stdout.strip() == "b true"
    return {"environment": environment, "enabled": enabled}


def restore_session(snapshot):
    failures = []
    # D-Bus UpdateActivationEnvironment has no API for deleting an entry. Restore
    # known old values; entries originally absent disappear on session restart.
    old = snapshot.get("environment")
    if old is not None:
        present = [f"{key}={value}" for key, value in old.items() if value is not None]
        absent = [key for key, value in old.items() if value is None]
        commands = []
        if present:
            commands.append(["systemctl", "--user", "set-environment", *present])
            commands.append(["dbus-update-activation-environment", *present])
        if absent:
            commands.append(["systemctl", "--user", "unset-environment", *absent])
        for args in commands:
            result = command(args)
            if result is None or result.returncode:
                failures.append(args[0])
    if snapshot.get("enabled") is not None:
        value = "true" if snapshot["enabled"] else "false"
        result = command(["busctl", "--user", "set-property", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled", "b", value])
        if result is None or result.returncode:
            failures.append("busctl")
    return failures


def snapshot(path):
    if not path.exists():
        return None
    if not path.is_file():
        raise ValueError(f"Not a regular configuration file: {path}")
    return {"text": path.read_text(), "mode": stat.S_IMODE(path.stat().st_mode)}


def atomic_write(path, text, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".zebry-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
            output.flush()
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def restore_file(path, original):
    if original is None:
        path.unlink(missing_ok=True)
    else:
        atomic_write(path, original["text"], original["mode"])


class Plan:
    def __init__(self):
        self.files = {}

    def text(self, path):
        path = path.resolve()
        if path in self.files:
            return self.files[path]["after"]["text"]
        return path.read_text() if path.exists() else ""

    def put(self, path, text, mode=None):
        # Follow existing dotfile symlinks instead of replacing the link.
        path = path.resolve()
        original = self.files[path]["before"] if path in self.files else snapshot(path)
        installed = {"text": text, "mode": mode if mode is not None else original["mode"] if original else 0o644}
        if original == installed:
            self.files.pop(path, None)
        else:
            self.files[path] = {"before": original, "after": installed}


def flags_text(text):
    # Remove conflicting switches even when several flags share a line. Keep
    # comments and unrelated flags; disable restores the exact original file.
    lines = []
    for line in text.splitlines(keepends=True):
        content, separator, comment = line.partition("#")
        content = re.sub(r"(?<!\S)--(?:force|disable)-renderer-accessibility(?:=[^\s#]+)?(?=\s|$)", "", content)
        lines.append(content + separator + comment)
    result = "".join(lines)
    if result and not result.endswith("\n"):
        result += "\n"
    return result + MARKER + "\n" + FLAG + "\n"


def mask_kdl(text):
    # Preserve offsets and newlines while ignoring quoted strings and comments.
    pattern = r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
    return re.sub(pattern, lambda match: "".join("\n" if c == "\n" else " " for c in match[0]), text)


def niri_environment(text):
    masked = mask_kdl(text)
    match = re.search(r"\benvironment\s*\{", masked)
    if match is None:
        return None
    start = masked.index("{", match.start()) + 1
    depth, end = 1, start
    while end < len(masked) and depth:
        depth += (masked[end] == "{") - (masked[end] == "}")
        end += 1
    if depth:
        raise ValueError("Unclosed Niri environment block")
    return start, end - 1


def niri_files(root, seen=None):
    seen = set() if seen is None else seen
    root = root.resolve()
    if root in seen:
        return []
    seen.add(root)
    text = root.read_text()
    result = [root]
    # Standard Niri includes with a quoted path, including relative dotfiles.
    masked = mask_kdl(text)
    for match in re.finditer(r'(?m)^[ \t]*include[ \t]+("(?:\\.|[^"\\])*")', text):
        if not re.match(r"[ \t]*include\b", masked[match.start():match.end()]):
            continue
        include = Path(json.loads(match[1])).expanduser()
        if not include.is_absolute():
            include = root.parent / include
        result.extend(niri_files(include, seen))
    return result


def configure_niri(plan, root, helper):
    if not root.exists():
        return
    blocks = [(path, niri_environment(plan.text(path))) for path in niri_files(root)]
    blocks = [(path, block) for path, block in blocks if block is not None]
    if len(blocks) > 1:
        raise ValueError("Multiple Niri environment blocks found; validate the Niri config first")
    if blocks:
        path, (start, end) = blocks[0]
        text = plan.text(path)
        body = text[start:end]
        keys = "|".join(VARIABLES)
        entry = rf'(?m)^[ \t]*(?:{keys})\s+(?:"(?:\\.|[^"\\])*"|null)[ \t]*;?[ \t]*(?://[^\n]*)?(?:\n|$)'
        body = re.sub(entry, "", body)
        # Reject less common inline forms instead of creating duplicate keys.
        if re.search(rf"\b(?:{keys})\b", mask_kdl(body)):
            raise ValueError(f"Unsupported inline accessibility entries in {path}")
        injected = "\n" + "".join(f'        {key} "{value}"\n' for key, value in VARIABLES.items())
        plan.put(path, text[:start] + injected + body.lstrip("\n") + text[end:])
    else:
        text = plan.text(root).rstrip("\n")
        body = "".join(f'    {key} "{value}"\n' for key, value in VARIABLES.items())
        plan.put(root, text + "\n\n" + KDL_MARKER + "\nenvironment {\n" + body + "}\n")
    text = plan.text(root).rstrip("\n")
    plan.put(root, text + "\n\n" + KDL_MARKER + '\nspawn-at-startup "sh" ' + json.dumps(str(helper), ensure_ascii=False) + "\n")


def session_script():
    exports = "\n".join(f"export {key}=1" for key in VARIABLES)
    assignments = " ".join(f"{key}=1" for key in VARIABLES)
    return f'''#!/bin/sh
# Managed by zebry setup-accessibility.py. Run once per login; no daemon.
{exports}
status=0
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user set-environment {assignments} || status=1
else
    status=1
fi
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment {assignments} || status=1
else
    status=1
fi
attempt=0
while [ "$attempt" -lt 5 ]; do
    if busctl --user --timeout=1s set-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled b true; then
        exit "$status"
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
exit 1
'''


def launcher_script():
    exports = "\n".join(f"export {key}=1" for key in VARIABLES)
    return f'''#!/bin/sh
# Managed by zebry setup-accessibility.py.
if [ "$#" -eq 0 ]; then
    echo "Usage: zebry-accessible-run PROGRAM [ARGUMENTS...]" >&2
    exit 2
fi
{exports}
program=$1
shift
exec "$program" {FLAG} "$@"
'''


def create_plan(config, data, args):
    plan = Plan()
    environment = MARKER + "\n" + "".join(f"{key}={value}\n" for key, value in VARIABLES.items())
    plan.put(config / "environment.d/90-zebry-accessibility.conf", environment)
    flag_files = {config / name for name in ("chrome-flags.conf", "chromium-flags.conf", "electron-flags.conf", "code-flags.conf")}
    flag_files.update(config.glob("electron*-flags.conf"))
    for path in sorted(flag_files):
        plan.put(path, flags_text(plan.text(path)))
    helper = data / "zebry/accessibility/session.sh"
    plan.put(helper, session_script(), 0o755)
    launcher = Path.home() / ".local/bin/zebry-accessible-run"
    plan.put(launcher, launcher_script(), 0o755)
    # XDG autostart covers desktops that support it. Niri explicitly invokes
    # the same idempotent helper, without relying on XDG autostart support.
    executable = '"' + str(helper).replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'
    executable = executable.replace("%", "%%")
    desktop = f"[Desktop Entry]\nType=Application\nName=Zebry accessibility\nExec=sh {executable}\nNoDisplay=true\n"
    plan.put(config / "autostart/zebry-accessibility.desktop", desktop)
    root = Path(args.niri_config).expanduser() if args.niri_config else Path(os.environ.get("NIRI_CONFIG", config / "niri/config.kdl")).expanduser()
    configure_niri(plan, root, helper)
    return plan, root, helper, launcher


def validate_niri(root):
    if root.exists() and shutil.which("niri"):
        result = command(["niri", "validate", "-c", str(root)])
        if result is None or result.returncode:
            raise ValueError("Niri validation failed:\n" + (result.stderr if result else "validation timed out"))


def load_state(path):
    if not path.exists():
        return None
    state = json.loads(path.read_text())
    if state.get("version") != 1:
        raise ValueError(f"Unsupported setup state: {path}")
    return state


def check_installed(state):
    conflicts = [entry["path"] for entry in state["files"] if snapshot(Path(entry["path"])) != entry["after"]]
    if conflicts:
        raise ValueError("Configuration changed since setup; no files were overwritten.\n"
                         + "\n".join(conflicts)
                         + "\nOriginal and installed contents are saved in the state.json backup.")


def main():
    parser = argparse.ArgumentParser(description="Configure per-user AT-SPI bridges and Chromium/Electron startup flags. No sudo required.")
    parser.add_argument("action", nargs="?", choices=("enable", "disable", "status"), default="enable")
    parser.add_argument("--dry-run", action="store_true", help="Show file changes without writing files or touching the session")
    parser.add_argument("--no-session", action="store_true", help="Only manage persistent files; do not query or change live D-Bus/systemd/Niri state")
    parser.add_argument("--niri-config", help="Niri root config (default NIRI_CONFIG or XDG_CONFIG_HOME/niri/config.kdl)")
    args = parser.parse_args()
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser().resolve()
    data = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser().resolve()
    state_path = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")).expanduser().resolve() / "zebry/accessibility/state.json"
    state = load_state(state_path)

    if args.action == "status":
        print("Persistent setup:", "enabled" if state else "not installed")
        if state:
            for entry in state["files"]:
                ok = snapshot(Path(entry["path"])) == entry["after"]
                print("  " + ("OK " if ok else "CHANGED ") + entry["path"])
            print("Backup:", state_path)
        if not args.no_session:
            live = session_snapshot()
            print("Session AT-SPI IsEnabled:", live["enabled"])
            print("User manager variables:", json.dumps(live["environment"]))
        return

    if args.action == "disable":
        if state is None:
            print("No Zebry accessibility setup to remove.")
            return
        check_installed(state)
        for entry in reversed(state["files"]):
            print("Restore:", entry["path"])
        if args.dry_run:
            print("Dry run: no files or session settings changed.")
            return
        restored = []
        try:
            for entry in reversed(state["files"]):
                restore_file(Path(entry["path"]), entry["before"])
                restored.append(entry)
            state_path.unlink()
        except (Exception, KeyboardInterrupt):
            for entry in reversed(restored):
                atomic_write(Path(entry["path"]), entry["after"]["text"], entry["after"]["mode"])
            raise
        if not args.no_session:
            failures = restore_session(state["session_before"])
            if failures:
                print("Session restoration unavailable for:", ", ".join(sorted(set(failures))))
            if os.environ.get("NIRI_SOCKET"):
                command(["niri", "msg", "action", "load-config-file", "--path", state["niri_config"]])
        print("Original configuration restored. Log out and back in to clear inherited/D-Bus activation variables.")
        return

    if state:
        check_installed(state)
        helper = Path(state["helper"])
        root = Path(state["niri_config"])
        print("Accessibility setup is already installed; no files changed.")
    else:
        plan, root, helper, launcher = create_plan(config, data, args)
        validate_niri(root)
        for path in plan.files:
            print("Configure:", path)
        if args.dry_run:
            print("Dry run: no files or session settings changed.")
            return
        state = {
            "version": 1,
            "niri_config": str(root.resolve()),
            "helper": str(helper),
            "session_before": {"environment": None, "enabled": None} if args.no_session else session_snapshot(),
            "files": [{"path": str(path), **entry} for path, entry in plan.files.items()],
        }
        if state_path.exists():
            raise ValueError(f"Setup state already exists: {state_path}")
        atomic_write(state_path, json.dumps(state, ensure_ascii=False, indent=2) + "\n", 0o600)
        written = []
        try:
            for entry in state["files"]:
                path = Path(entry["path"])
                atomic_write(path, entry["after"]["text"], entry["after"]["mode"])
                written.append(entry)
            validate_niri(root)
        except (Exception, KeyboardInterrupt):
            for entry in reversed(written):
                restore_file(Path(entry["path"]), entry["before"])
            state_path.unlink(missing_ok=True)
            raise
        print("Backup:", state_path)
        print("For independent Electron apps: ", launcher, "PROGRAM [ARGUMENTS...]")

    if args.dry_run:
        print("Dry run: no files or session settings changed.")
        return
    if not args.no_session:
        if state["session_before"] == {"environment": None, "enabled": None}:
            state["session_before"] = session_snapshot()
            atomic_write(state_path, json.dumps(state, ensure_ascii=False, indent=2) + "\n", 0o600)
        result = command(["sh", str(helper)])
        if result is None or result.returncode:
            print("Persistent setup saved; current session could not be fully updated. Log out and back in.")
        else:
            print("Current user session accessibility bridge enabled.")
        if os.environ.get("NIRI_SOCKET"):
            command(["niri", "msg", "action", "load-config-file", "--path", str(root)])
    print("Restart existing Chrome/Chromium/Electron processes completely; future supported launchers use the saved flags.")
    print("Electron bundles may ignore flags.conf: use zebry-accessible-run for those apps.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
