#!/usr/bin/env bash
# Install the LaunchAgent that keeps toreplyd running on the Mac mini.
#
# Run this ON the Mac mini (or via: ssh <mac> 'bash -s' < tools/install-agent.sh).
#
# IMPORTANT — permissions. Over SSH, toreplyd inherits the SSH daemon's Full Disk
# Access, which is why it can read chat.db during development. A launchd-managed
# process does NOT inherit that: macOS scopes Full Disk Access and Automation to the
# binary being launched. After installing, run `toreplyd doctor`; if chat.db can't be
# opened, add this binary in:
#
#   System Settings → Privacy & Security → Full Disk Access
#     /Users/<you>/toreply/server/.build/release/toreplyd
#
# and approve the Messages automation prompt the first time it sends.
set -euo pipefail

LABEL="com.alexa.toreplyd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY="$HOME/toreply/bin/toreplyd"

if [[ ! -x "$BINARY" ]]; then
  echo "error: $BINARY not found — run ./deploy.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/.toreply" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
        <string>serve</string>
        <string>--bind</string>
        <string>${TOREPLY_BIND:-auto}</string>
        <string>--port</string>
        <string>${TOREPLY_PORT:-8787}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$HOME/.toreply/toreplyd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.toreply/toreplyd.err</string>

    <!-- Interactive, not Background: a Background ProcessType gets aggressively
         throttled, which would make the poll loop and sends sluggish. -->
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

sleep 3

if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "✗ agent did not start — check ~/.toreply/toreplyd.err" >&2
  exit 1
fi

# The agent will happily "run" while failing every second, so check what it actually did.
if grep -q "Full Disk Access" "$HOME/.toreply/toreplyd.err" 2>/dev/null; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  cat <<'MSG'

✗ The agent started but macOS denied it access to chat.db, so it has been unloaded
  again (KeepAlive would otherwise respawn it in a loop).

  Full Disk Access is granted per binary. Reading chat.db over SSH works because the
  SSH daemon already has it; a launchd process gets no such inheritance.

  To fix, once:

    1. System Settings → Privacy & Security → Full Disk Access
    2. "+", then press Cmd-Shift-G and paste:
         ~/toreply/bin/toreplyd
    3. Make sure its toggle is ON
    4. Re-run this script

  The binary is ad-hoc signed with a stable identifier (com.alexa.toreplyd), so this
  grant survives future rebuilds — you only do it once.

MSG
  exit 1
fi

echo "✓ $LABEL installed and running"
echo "  logs: ~/.toreply/toreplyd.log"
