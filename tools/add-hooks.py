#!/usr/bin/env python3
"""Add the Photosynthesizing hook to a Claude Code settings file, keeping everything else.

    add-hooks.py <settings.json> <path to hook/tv_hook.py>

Adds one entry per event and skips any event that already has it, so running it twice
changes nothing. Writes a .bak copy first.
"""
import json
import os
import shutil
import sys

EVENTS = ["UserPromptSubmit", "Stop", "Notification", "PostToolUse", "SessionEnd"]


def main(settings_path, hook_path):
    settings = {}
    if os.path.exists(settings_path):
        with open(settings_path) as f:
            settings = json.load(f)
        shutil.copy(settings_path, settings_path + ".bak")

    command = f"/usr/bin/python3 {hook_path}"
    hooks = settings.setdefault("hooks", {})
    added = []
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        if any(hook_path in json.dumps(entry) for entry in entries):
            continue
        entries.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
        added.append(event)

    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
    print("hooks added for: " + (", ".join(added) if added else "nothing (already there)"))


if __name__ == "__main__":
    main(sys.argv[1], os.path.abspath(sys.argv[2]))
