#!/bin/bash
# Booster — play on your phone.
# Run this, then open the printed address in Safari on your iPhone
# (phone and Mac must be on the same Wi-Fi, or the Mac on the phone's hotspot).
cd "$(dirname "$0")"
PORT=8090
NAME=$(scutil --get LocalHostName)
echo ""
echo "  🚀 Booster phone server starting…"
echo ""
echo "  On your iPhone, open Safari and go to:"
echo ""
echo "      http://${NAME}.local:${PORT}"
echo ""
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
[ -n "$IP" ] && echo "  (if that doesn't load, try:  http://${IP}:${PORT} )" && echo ""
echo "  Tip: in Safari tap Share → 'Add to Home Screen' to install it like an app."
echo "  Leave this window open while playing. Press Ctrl+C to stop."
echo ""
# caffeinate -i keeps the Mac awake while the server runs
exec caffeinate -i python3 -m http.server "$PORT" --bind ::
