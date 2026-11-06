#!/bin/bash
# Pretends Claude is working for N seconds (default 60), for demos: the strip slides in
# after 4s, and when the time is up it shows "Claude's done" with the green screen glow.
# Writes the same file the Claude Code hook writes, so it exercises the real path.
set -euo pipefail
SECONDS_TO_WORK="${1:-60}"
FILE="$HOME/.claude-tv/working/demo"
trap 'rm -f "$FILE"' EXIT
printf '{"started": %s, "pid": 0, "project": "demo", "prompt": "demo"}' "$(date +%s)" > "$FILE"
echo "Claude is \"working\" for ${SECONDS_TO_WORK}s… (Ctrl-C to finish early)"
sleep "$SECONDS_TO_WORK"
echo "Done."
