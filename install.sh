#!/bin/bash
# Set up Photosynthesizing on the Mac you use Claude Code on. One Mac, no Tailscale.
#
#   ./install.sh
#
# Builds the server and the strip, starts both at login, points the strip at the server,
# and adds the Claude Code hook. Safe to run again after pulling changes. The one step it
# can't do for you is Full Disk Access; it opens the right settings page at the end.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"

SERVER_LABEL="com.photosynthesizing.server"
STRIP_LABEL="com.photosynthesizing.strip"
AGENTS="$HOME/Library/LaunchAgents"
BIN="$HOME/toreply/bin/toreplyd"
PORT=8787

say() { printf '\n▸ %s\n' "$1"; }

say "Building the server"
(cd server && swift build -c release 2>&1 | grep -E "error|warning: unre|Build complete") || {
  echo "Build failed. You need Xcode or the Xcode command line tools (xcode-select --install)."
  exit 1
}
mkdir -p "$(dirname "$BIN")" "$HOME/.toreply" "$AGENTS"
cp -f server/.build/release/toreplyd "$BIN"

# Full Disk Access is stored against the binary's signature. Signed with your Apple
# Development certificate, the grant survives rebuilds; signed ad hoc, every rebuild
# needs a new grant.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }')
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$SERVER_LABEL" "$BIN"
else
  echo "  No Apple Development certificate found; signing ad hoc. You'll need to re-grant"
  echo "  Full Disk Access after each rebuild. (Signing into Xcode with your Apple ID creates one.)"
  codesign --force --sign - --identifier "$SERVER_LABEL" "$BIN"
fi

write_agent() { # label, then the program and its arguments
  local label="$1"; shift
  local args=""
  for arg in "$@"; do args+="<string>$arg</string>"; done
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>$args</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/.toreply/$label.err</string>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$label.plist"
}

say "Starting the server (listens only on this Mac)"
# 127.0.0.1 only: nothing else on your network can reach it.
write_agent "$SERVER_LABEL" "$BIN" serve --bind 127.0.0.1 --port "$PORT"

say "Building the strip"
(cd strip && ./build.sh)
APP="$REPO/strip/build/Photosynthesizing.app"

say "Pointing the strip at the server"
# The server only creates its token once it can read Messages, which needs the Full Disk
# Access grant at the end, so make one now in the same format; the server reuses it.
if [[ ! -s "$HOME/.toreply/token" ]]; then
  ( umask 077; openssl rand -hex 24 > "$HOME/.toreply/token" )
fi
mkdir -p "$HOME/.claude-tv"
TOKEN=$(tr -d '[:space:]' < "$HOME/.toreply/token")
( umask 077
  printf '{"baseURL": "http://127.0.0.1:%s/", "token": "%s"}\n' "$PORT" "$TOKEN" > "$HOME/.claude-tv/config.json" )
write_agent "$STRIP_LABEL" "$APP/Contents/MacOS/Photosynthesizing"

say "Adding the Claude Code hook"
python3 tools/add-hooks.py "$HOME/.claude/settings.json" "$REPO/hook/tv_hook.py"

say "Last step: Full Disk Access"
cat <<EOF
  The server reads your Messages, call history and Contacts (read-only), which macOS
  only allows with Full Disk Access. In the window that just opened:

    + → press ⌘⇧G → paste:  $BIN  → Open → make sure it's switched on

  Then restart the server:

    launchctl kickstart -k gui/$(id -u)/$SERVER_LABEL

  Optional, for WhatsApp, Instagram and Messenger: install Beeper Desktop, turn on its
  Desktop API (Settings → Integrations), and save a token to ~/.toreply/beeper-token.

  Check it any time with:  $BIN doctor
EOF
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" || true
