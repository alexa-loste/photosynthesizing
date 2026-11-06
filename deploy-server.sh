#!/usr/bin/env bash
# Build both halves and push them to the always-on Mac.
#
#   ./deploy-server.sh     build on the always-on Mac, sign, install, restart
set -euo pipefail
cd "$(dirname "$0")"

# Config lives in toreply.env (see toreply.env.example). Nothing machine-specific is
# baked into this script, so a second person can clone the repo and run it unmodified.
[[ -f toreply.env ]] && source toreply.env
REMOTE="${TOREPLY_REMOTE:-mini}"
BIND="${TOREPLY_BIND:-auto}"
PORT="${TOREPLY_PORT:-8787}"

echo "▸ syncing to $REMOTE"
rsync -az --delete --exclude '.build' server/ "$REMOTE:toreply/server/"

echo "▸ building server"
# pipefail, or grep's exit code hides a failed build and the old binary gets redeployed.
ssh "$REMOTE" 'set -o pipefail; cd ~/toreply/server && swift build -c release 2>&1 | grep -E "error|Build complete"'

# Sign with the Apple Development certificate, install, restart.
#
# Full Disk Access is stored against the binary's designated requirement. The old ad-hoc
# signature's requirement was its cdhash, which changes every build, so every deploy
# silently revoked the grant (the daemon then crash-looped from Aug 21 to Nov 5 2026).
# A certificate signature's requirement survives rebuilds. Signing needs the login
# keychain, so it runs as a one-shot agent in the GUI session; see tools/sign-daemon.sh.
echo "▸ signing and installing"
scp -q tools/sign-daemon.sh "$REMOTE:toreply/bin/sign-daemon.sh"
ssh "$REMOTE" 'bash -s' <<'REMOTE_SCRIPT'
set -e
cp -f ~/toreply/server/.build/release/toreplyd ~/toreply/bin/toreplyd.new
rm -f ~/.toreply/sign.status
RESTART=""
launchctl print gui/$(id -u)/com.alexa.toreplyd >/dev/null 2>&1 && RESTART="<string>--restart</string>"
PLIST=~/Library/LaunchAgents/com.alexa.toreplyd.sign.plist
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.alexa.toreplyd.sign</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$HOME/toreply/bin/sign-daemon.sh</string>
    <string>$HOME/toreply/bin/toreplyd.new</string><string>$HOME/toreply/bin/toreplyd</string>
    $RESTART
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
launchctl bootout gui/$(id -u)/com.alexa.toreplyd.sign 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
for _ in $(seq 1 60); do [ -f ~/.toreply/sign.status ] && break; sleep 1; done
launchctl bootout gui/$(id -u)/com.alexa.toreplyd.sign 2>/dev/null || true
STATUS=$(cat ~/.toreply/sign.status 2>/dev/null || echo "timed out")
echo "  sign: $STATUS"
[ "$STATUS" = ok ]
REMOTE_SCRIPT

if ssh "$REMOTE" 'launchctl print gui/$(id -u)/com.alexa.toreplyd >/dev/null 2>&1'; then
  echo "  launch agent restarted"
else
  # `ssh -n` plus `< /dev/null` on the daemon, both deliberately. ssh does not exit until
  # every inherited file descriptor is closed, and a backgrounded process holds the
  # session's stdin open — so without these the daemon starts fine and the script hangs
  # forever afterwards, which reads exactly like a failed deploy and is not one.
  ssh -n "$REMOTE" "pkill -f 'toreplyd serve' 2>/dev/null || true
                 nohup ~/toreply/bin/toreplyd serve --bind '$BIND' --port '$PORT' \
                   < /dev/null > ~/.toreply/toreplyd.log 2>&1 &
                 sleep 2"
  echo "  started manually (launch agent not installed — see install-agent.sh)"
fi

URL=$(ssh "$REMOTE" "grep -o 'listening on http://[^ ]*' ~/.toreply/toreplyd.log 2>/dev/null | tail -1" || true)
echo "✓ ${URL:-deployed}"
