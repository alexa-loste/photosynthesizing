#!/usr/bin/env python3
"""Claude Code hook that tells the strip when a prompted session is working.

State is plain files so the strip app only has to watch a directory:

    ~/.claude-tv/working/<session_id>    a turn you prompted is running
    ~/.claude-tv/attention/<session_id>  that turn is waiting on you (permission, question)
    ~/.claude-tv/done/<session_id>       that turn finished; cleared by your next prompt there

Wired to UserPromptSubmit, Stop, Notification, PostToolUse and SessionEnd. It must never block or
fail a turn, so every path exits 0 and prints nothing.
"""
import json
import os
import sys
import time

ROOT = os.path.expanduser("~/.claude-tv")
WORKING = os.path.join(ROOT, "working")
ATTENTION = os.path.join(ROOT, "attention")
DONE = os.path.join(ROOT, "done")
LOG = os.path.join(ROOT, "hook.log")

# Turns the desktop app starts on its own. They arrive as UserPromptSubmit like a typed
# prompt, but nobody is sitting there waiting on them.
AUTOMATED_PREFIXES = (
    "<side-sessions-event",
    "<<autonomous-loop",
    "<ci-monitor-event",
    "<task-notification",
    "[Artifact comment",
    "<scheduled-task",
)


def log(event, session, note):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {event} {session[:8]} {note}\n")
    except OSError:
        pass


def remove(directory, session):
    try:
        os.remove(os.path.join(directory, session))
    except FileNotFoundError:
        pass


def is_prompted_by_a_person(payload):
    prompt = (payload.get("prompt") or "").lstrip()
    if prompt.startswith(AUTOMATED_PREFIXES):
        return False, "automated prefix"
    # Background `claude -p` runs (joist, harnesses) are not attended.
    if os.environ.get("CLAUDE_CODE_SESSION_ATTENDED", "1") == "0":
        return False, "unattended"
    return True, ""


def main():
    payload = json.load(sys.stdin)
    event = payload.get("hook_event_name", "")
    session = payload.get("session_id", "")
    if not session:
        return
    for directory in (WORKING, ATTENTION, DONE):
        os.makedirs(directory, exist_ok=True)

    if event == "UserPromptSubmit":
        prompted, reason = is_prompted_by_a_person(payload)
        remove(ATTENTION, session)
        remove(DONE, session)
        if not prompted:
            log(event, session, f"skip ({reason})")
            return
        record = {
            "started": time.time(),
            "pid": int(os.environ.get("CLAUDE_PID", "0") or 0),
            "project": os.path.basename(payload.get("cwd", "").rstrip("/")),
            "prompt": (payload.get("prompt") or "")[:80],
        }
        with open(os.path.join(WORKING, session), "w") as f:
            json.dump(record, f)
        log(event, session, f"working in {record['project']}")

    elif event == "Notification":
        # Only matters for a turn the strip is already showing for.
        if os.path.exists(os.path.join(WORKING, session)):
            open(os.path.join(ATTENTION, session), "w").close()
            log(event, session, "needs you")

    elif event == "PostToolUse":
        # Claude ran a tool, so whatever it was waiting on (a question, a permission)
        # has been answered and it's working again.
        if os.path.exists(os.path.join(ATTENTION, session)):
            remove(ATTENTION, session)
            log(event, session, "working again")

    elif event == "Stop":
        working = os.path.join(WORKING, session)
        if os.path.exists(working):
            # Keep what the turn was about, so the strip can say which session finished.
            try:
                with open(working) as f:
                    record = json.load(f)
            except (OSError, ValueError):
                record = {}
            record["finished"] = time.time()
            with open(os.path.join(DONE, session), "w") as f:
                json.dump(record, f)
            log(event, session, "done")
        remove(WORKING, session)
        remove(ATTENTION, session)

    elif event == "SessionEnd":
        for directory in (WORKING, ATTENTION, DONE):
            remove(directory, session)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # a hook must never break the turn
        log("error", "-" * 8, repr(error))
    sys.exit(0)
