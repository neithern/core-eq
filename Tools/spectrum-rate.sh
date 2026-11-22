#!/bin/sh
#
# Reads or writes the rate the response plot's spectrum is analysed at.
#
#   Tools/spectrum-rate.sh          print the rate the app will use
#   Tools/spectrum-rate.sh 15       write 15 Hz, then restart CoreEQ
#
# There is no control for this in Settings on purpose: it exists so the
# backdrop's cost can be measured at different rates. The app reads the stored
# value once at launch, because a 'defaults write' from another process does not
# notify a running one — so a write is only useful if the app is restarted,
# which this script does.
#
# The bundle identifier is read from the built app when there is one, so a
# renamed build keeps working.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${COREEQ_APP:-$ROOT/build/Release/CoreEQ.app}"
DEFAULT=30
MIN=5
MAX=60

if [ -f "$APP/Contents/Info.plist" ]; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
else
    BUNDLE_ID=com.andreypudov.coreeq
fi

current() {
    defaults read "$BUNDLE_ID" spectrumFramesPerSecond 2>/dev/null || echo "$DEFAULT"
}

if [ $# -eq 0 ]; then
    echo "spectrum rate: $(current) Hz (default $DEFAULT, range $MIN-$MAX)"
    exit 0
fi

RATE=$1
case "$RATE" in
    ''|*[!0-9.]*)
        echo "error: '$RATE' is not a number" >&2
        exit 1
        ;;
esac

CLAMPED=$(awk -v r="$RATE" -v lo="$MIN" -v hi="$MAX" \
    'BEGIN { if (r < lo) r = lo; if (r > hi) r = hi; printf "%g", r }')
if [ "$CLAMPED" != "$RATE" ]; then
    echo "note: $RATE Hz is outside $MIN-$MAX, using $CLAMPED Hz" >&2
fi

defaults write "$BUNDLE_ID" spectrumFramesPerSecond -float "$CLAMPED"
echo "spectrum rate: $(current) Hz"

if ! pgrep -x CoreEQ >/dev/null 2>&1; then
    echo "CoreEQ is not running; it will use this rate the next time it starts."
    exit 0
fi

echo "restarting CoreEQ..."
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

i=0
while pgrep -x CoreEQ >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
if pgrep -x CoreEQ >/dev/null 2>&1; then
    echo "note: CoreEQ did not quit; asking it to terminate" >&2
    killall CoreEQ 2>/dev/null || true
    sleep 0.5
fi

if [ -d "$APP" ]; then
    open "$APP"
else
    open -b "$BUNDLE_ID"
fi
