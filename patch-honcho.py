#!/usr/bin/env python3
"""Re-apply local patches to the Honcho Claude Code plugin after it updates.

- Hides Honcho's per-turn notices in the Claude Code UI (captured / saved / injected / skipped).
- Makes the hooks write ~/.honcho/status-<session_id>.json for the statusline's 🧠 segment.

Safe to run repeatedly: already-applied patches are skipped. Each file is syntax-checked with
`node --check` and restored from its .orig backup if the check fails.

Usage: patch-honcho.py [hooks_dir]   (default: newest installed honcho plugin)
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

MARKER = "local patch"

HELPER = '''// local patch: per-session summary for the Claude Code statusline
function honchoStatus(sid, update) {
  if (!sid) return;
  try {
    const fs = process.getBuiltinModule("fs"), path = process.getBuiltinModule("path"), os = process.getBuiltinModule("os");
    const f = path.join(os.homedir(), ".honcho", `status-${sid}.json`);
    let s = {};
    try { s = JSON.parse(fs.readFileSync(f, "utf8")); } catch {}
    fs.writeFileSync(f, JSON.stringify({ ...s, ...update(s), ts: Date.now() }));
  } catch {}
}
'''
VIS_STOP = "function visStopMessage(direction, message) {"
ADD_SYSTEM_MESSAGE = "  return { ...existingJson, systemMessage: message };"
HIDDEN_ADD_SYSTEM_MESSAGE = "  return existingJson; // local patch: hide injection notice"

# file -> list of (name, old, new); old must occur exactly once
PATCHES = {
    "post-tool-use.js": [
        ("status helper", VIS_STOP, HELPER + VIS_STOP),
        ("hide captured notice",
         '  visMessage("out", "post-tool-use", `captured: ${summary}`);\n}\nfunction visSkipMessage',
         '  return; // local patch: hide capture notice\n}\nfunction visSkipMessage'),
        ("count captures",
         "  visCapture(summary);\n",
         "  visCapture(summary);\n"
         "  honchoStatus(hookInput.session_id, (s) => ({ captured: (s.captured || 0) + 1 }));\n"),
    ],
    "stop.js": [
        ("status helper", VIS_STOP, HELPER + VIS_STOP),
        ("hide saved notice, count saves",
         '    visStopMessage("out", `saved ${turnMessages.length} assistant msg(s)`);\n',
         '    // local patch: hide per-turn "saved" notice\n'
         "    honchoStatus(instanceId, (s) => ({ saved: (s.saved || 0) + turnMessages.length, save_ts: Date.now() }));\n"),
    ],
    "user-prompt.js": [
        ("status helper", VIS_STOP, HELPER + VIS_STOP),
        ("hide injection notice", ADD_SYSTEM_MESSAGE, HIDDEN_ADD_SYSTEM_MESSAGE),
        ("hide skip notice",
         'function visSkipMessage(hookName, reason) {\n  visMessage("info", hookName, `skipped (${reason})`);\n}',
         'function visSkipMessage(hookName, reason) {\n  return; // local patch: hide skip notice\n}'),
        ("remember session id",
         "  const instanceId = hookInput.session_id || getInstanceIdForCwd(cwd);\n",
         "  const instanceId = hookInput.session_id || getInstanceIdForCwd(cwd);\n"
         "  globalThis.__honchoSid = hookInput.session_id;\n"),
        ("count recalled conclusions",
         "  if (parts.length === 0)\n    return;\n  const visMsg = visLines.join(",
         "  honchoStatus(globalThis.__honchoSid, () => ({ recalled: visLines.reduce((n, l) => n + "
         "Number((l.match(/injected (\\d+)/) || [0, 0])[1]), 0), recall_ts: Date.now() }));\n"
         "  if (parts.length === 0)\n    return;\n  const visMsg = visLines.join("),
    ],
    "session-start.js": [
        ("hide injection notice", ADD_SYSTEM_MESSAGE, HIDDEN_ADD_SYSTEM_MESSAGE),
        ("hide session-start notice",
         '        systemMessage: visComposedInjection("session-start", rendered.labels)\n',
         "        // local patch: injection notice hidden\n"),
    ],
}


def find_hooks_dir() -> Path:
    installed = Path.home() / ".claude/plugins/installed_plugins.json"
    try:
        entries = json.loads(installed.read_text())["plugins"]["honcho@honcho"]
        path = Path(max(entries, key=lambda e: e.get("lastUpdated", ""))["installPath"]) / "dist/hooks"
        if path.is_dir():
            return path
    except (OSError, KeyError, ValueError):
        pass
    candidates = sorted((Path.home() / ".claude/plugins/cache/honcho/honcho").glob("*/dist/hooks"))
    if not candidates:
        sys.exit("Honcho plugin not found; pass the hooks dir as an argument")
    return candidates[-1]


def patch_file(path: Path, patches) -> bool:
    src = path.read_text()
    original = src
    ok = True
    for name, old, new in patches:
        if new in src:
            print(f"  = {name} (already applied)")
        elif src.count(old) == 1:
            src = src.replace(old, new)
            print(f"  + {name}")
        else:
            print(f"  ! {name}: pattern not found ({src.count(old)} matches), plugin code changed")
            ok = False
    if src == original:
        return ok

    backup = path.with_name(path.name + ".orig")
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(src)
    if subprocess.run(["node", "--check", str(path)], capture_output=True).returncode != 0:
        path.write_text(original)
        print(f"  ! syntax check failed, {path.name} restored")
        return False
    return ok


def main() -> int:
    hooks = Path(sys.argv[1]) if len(sys.argv) > 1 else find_hooks_dir()
    print(f"Patching {hooks}")
    all_ok = True
    for name, patches in PATCHES.items():
        path = hooks / name
        print(name)
        if not path.exists():
            print("  ! file missing")
            all_ok = False
            continue
        all_ok &= patch_file(path, patches)
    print("Done." if all_ok else "Done with problems; see '!' lines above.")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
