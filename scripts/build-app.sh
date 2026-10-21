#!/bin/bash
# Build Pulls with Swift Package Manager and wrap the executable in a menu-bar .app.
# Does not generate an Xcode project.
#
#   scripts/build-app.sh            # release bundle at ./Pulls.app
#   scripts/build-app.sh --debug
#   scripts/build-app.sh --launch   # build, then open the bundle

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="release"
LAUNCH=0

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIGURATION="debug"
      ;;
    --launch)
      LAUNCH=1
      ;;
    -h|--help)
      echo "Usage: scripts/build-app.sh [--debug] [--launch]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# Static Swift stdlib so the bundle runs without the toolchain's library path.
swift build -c "$CONFIGURATION" --static-swift-stdlib --product pulls

BINARY="$ROOT/.build/$CONFIGURATION/pulls"
if [[ ! -f "$BINARY" ]]; then
  echo "Missing built executable at $BINARY" >&2
  exit 1
fi

APP="$ROOT/Pulls.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Pulls"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/Pulls"

# Ad-hoc signature lets `open` launch a local bundle that never saw Xcode.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# LSUIElement in Info.plist is what keeps the app out of the Dock.
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" >/dev/null

echo "Built $APP"

if [[ "$LAUNCH" -eq 1 ]]; then
  if pgrep -x Pulls >/dev/null 2>&1; then
    pkill -x Pulls || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      if ! pgrep -x Pulls >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  fi
  open "$APP"
  echo "Launched Pulls. Click the menu-bar item labeled with the PR count."
fi
