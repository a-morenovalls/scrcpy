#!/usr/bin/env bash
#
# Build a self-contained scrcpy.app for macOS (host architecture).
#
# Usage: release/make_macos_app.sh [path/to/scrcpy-server]
#
# The server defaults to the one installed by Homebrew (it must match the
# client version). The result is written to dist/scrcpy.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build-app-release"
APP="$ROOT/dist/scrcpy.app"
SERVER="${1:-/opt/homebrew/share/scrcpy/scrcpy-server}"
ADB="${ADB:-$(command -v adb || true)}"
VERSION="$(sed -n "s/.*version: '\(.*\)',/\1/p" "$ROOT/meson.build" | head -1)"

[[ -f "$SERVER" ]] || { echo "scrcpy-server not found: $SERVER" >&2; exit 1; }

# Release build of the client only (the server is not rebuilt)
if [[ ! -d "$BUILD" ]]; then
    meson setup "$BUILD" "$ROOT" --buildtype=release -Dportable=false
fi
ninja -C "$BUILD" app/scrcpy

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Frameworks"

cp "$BUILD/app/scrcpy" "$APP/Contents/MacOS/scrcpy-bin"
cp "$SERVER" "$APP/Contents/Resources/scrcpy-server"
cp "$ROOT/app/data/disconnected.png" "$APP/Contents/Resources/"
# The icon of the app (see release/make_icon.swift). scrcpy also uses scrcpy.png
# as the window icon.
sips -z 512 512 "$ROOT/app/data/macos-icon.png" \
    --out "$APP/Contents/Resources/scrcpy.png" >/dev/null
if [[ -n "$ADB" ]]; then
    cp "$ADB" "$APP/Contents/MacOS/adb"
fi

# Icon
ICONSET="$(mktemp -d)/scrcpy.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256; do
    sips -z $size $size "$ROOT/app/data/macos-icon.png" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/app/data/macos-icon.png" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/scrcpy.icns"

# Launcher: GUI apps do not inherit the shell PATH
cat > "$APP/Contents/MacOS/scrcpy" <<'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$DIR/../Resources"
export PATH="$DIR:/opt/homebrew/bin:/usr/local/bin:$PATH"
export ADB="$DIR/adb"
[[ -x "$ADB" ]] || unset ADB
export SCRCPY_SERVER_PATH="$RES/scrcpy-server"
export SCRCPY_ICON_DIR="$RES"

LOG="$HOME/Library/Logs/scrcpy.log"
mkdir -p "$(dirname "$LOG")"

ADB_BIN="${ADB:-adb}"

if ! "$ADB_BIN" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
    # No device: offer to connect over Wi-Fi (adb mdns finds devices with
    # Wireless debugging enabled)
    FOUND="$("$ADB_BIN" mdns services 2>/dev/null \
        | awk '$0 ~ /_adb-tls-connect/ {print $NF; exit}')"
    ANSWER="$(osascript <<OSA 2>/dev/null
text returned of (display dialog "No USB device found.\n\nTo connect over Wi-Fi, enter the device address (IP or IP:port). Wireless debugging must be enabled on the device." default answer "$FOUND" buttons {"Cancel", "Connect"} default button "Connect" with title "scrcpy")
OSA
)" || exit 1
    ANSWER="${ANSWER// /}"
    [[ -n "$ANSWER" ]] || exit 1
    [[ "$ANSWER" == *:* ]] || ANSWER="$ANSWER:5555"

    OUT="$("$ADB_BIN" connect "$ANSWER" 2>&1)"
    if [[ "$OUT" != *"connected to"* ]]; then
        osascript -e "display dialog \"Could not connect to $ANSWER:\n\n$OUT\" buttons {\"OK\"} default button \"OK\" with icon caution with title \"scrcpy\"" >/dev/null 2>&1
        exit 1
    fi
    set -- -s "$ANSWER" "$@"
fi

# Several devices: scrcpy refuses to choose. A phone seen both over USB and
# Wi-Fi uses USB; otherwise the user picks one.
HAS_SELECTOR=0
for arg in "$@"; do
    case "$arg" in -s|--serial|--serial=*|-d|-e|--select-usb|--select-tcpip) HAS_SELECTOR=1;; esac
done
if [[ $HAS_SELECTOR -eq 0 ]]; then
    DEVICES="$("$ADB_BIN" devices -l 2>/dev/null | awk 'NR>1 && $2=="device" {
        model=""; for (i=3;i<=NF;i++) if ($i ~ /^model:/) model=substr($i,7);
        print $1 "|" model }')"
    COUNT="$(printf '%s\n' "$DEVICES" | grep -c .)"
    if [[ "$COUNT" -gt 1 ]]; then
        MODELS="$(printf '%s\n' "$DEVICES" | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')"
        if [[ "$MODELS" -eq 1 ]]; then
            USB="$(printf '%s\n' "$DEVICES" | cut -d'|' -f1 | grep -v -e ':' -e '_adb-tls' | head -1)"
            CHOSEN="${USB:-$(printf '%s\n' "$DEVICES" | head -1 | cut -d'|' -f1)}"
        else
            LIST="$(printf '%s\n' "$DEVICES" | awk -F'|' '{printf "%s\"%s - %s\"", (NR>1?", ":""), $2, $1}')"
            PICK="$(osascript -e "choose from list {$LIST} with title \"scrcpy\" with prompt \"Choose one or more devices:\" with multiple selections allowed" 2>/dev/null)"
            [[ -n "$PICK" && "$PICK" != "false" ]] || exit 1
            # "model - serial, model - serial": the first one is this window,
            # each other device gets its own one
            IFS=$'\n' read -r -d '' -a PICKED < <(printf '%s' "$PICK" | sed 's/, /\n/g'; printf '\0')
            CHOSEN="${PICKED[0]##* - }"
            for ((i = 1; i < ${#PICKED[@]}; i++)); do
                "$DIR/scrcpy" -s "${PICKED[i]##* - }" >/dev/null 2>&1 &
                disown
            done
        fi
        set -- -s "$CHOSEN" "$@"
    fi
fi

# Stream quality (Device > Stream Quality). "auto" tunes the stream for Wi-Fi
# and leaves USB untouched. Skipped if the user passes their own video options.
QUALITY="$(defaults read com.genymobile.scrcpy.app scrcpy.quality 2>/dev/null || echo auto)"
USER_VIDEO=0
SERIAL=""
HAS_S=0
PREV=""
for arg in "$@"; do
    case "$arg" in
        -b*|--video-bit-rate*|-m*|--max-size*|--max-fps*|--video-codec*|--video-buffer*) USER_VIDEO=1;;
        --serial=*) SERIAL="${arg#--serial=}"; HAS_S=1;;
    esac
    [[ "$PREV" == "-s" ]] && { SERIAL="$arg"; HAS_S=1; }
    PREV="$arg"
done
if [[ -z "$SERIAL" ]]; then
    SERIAL="$("$ADB_BIN" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [[ -n "$SERIAL" ]]; then
    # Always explicit: the sessions of the other devices find each other by it,
    # and each device has its own log
    [[ $HAS_S -eq 0 ]] && set -- -s "$SERIAL" "$@"
    LOG="$HOME/Library/Logs/scrcpy-${SERIAL//[^A-Za-z0-9._-]/_}.log"
fi
FPS="$(defaults read com.genymobile.scrcpy.app scrcpy.fps 2>/dev/null || echo auto)"

if [[ $USER_VIDEO -eq 0 && -n "$SERIAL" ]]; then
    WIFI=0
    [[ "$SERIAL" == *:* || "$SERIAL" == *_adb-tls* ]] && WIFI=1
    PROFILE="$QUALITY"
    if [[ "$PROFILE" == "auto" ]]; then
        [[ $WIFI -eq 1 ]] && PROFILE="balanced" || PROFILE="default"
    fi
    FLAGS=()
    case "$PROFILE" in
        balanced) FLAGS=(-m1600 -b6M --max-fps=60);;
        saver)    FLAGS=(-m1024 -b3M --max-fps=30);;
        high)     FLAGS=(-b16M --max-fps=60);;
    esac
    if [[ ${#FLAGS[@]} -gt 0 ]]; then
        # H.265 needs about half the bitrate of H.264 for the same quality;
        # use it when the device has a hardware encoder
        if "$DIR/scrcpy-bin" -s "$SERIAL" --list-encoders 2>&1 \
                | grep -q 'video-codec=h265.*(hw)'; then
            FLAGS+=(--video-codec=h265)
        fi
        # Constant bitrate avoids the spikes that stall a Wi-Fi link
        [[ "$PROFILE" != "high" ]] && FLAGS+=(--video-codec-options=bitrate-mode:int=2)
    fi
    # Maximum frame rate chosen in the menu, over the one of the profile
    case "$FPS" in 30|45|60|90|120) FLAGS+=("--max-fps=$FPS");; esac
    if [[ ${#FLAGS[@]} -gt 0 ]]; then
        set -- "${FLAGS[@]}" "$@"
    fi
fi

# Audio output (Device > Audio Output) and screen off at start (Device > Start
# With Device Screen Off). Skipped if the user passes their own audio options.
USER_AUDIO=0
for arg in "$@"; do
    case "$arg" in
        --no-audio|--audio-*|--turn-screen-off|-S) USER_AUDIO=1;;
    esac
done
if [[ $USER_AUDIO -eq 0 ]]; then
    EXTRA=()
    AUDIO="$(defaults read com.genymobile.scrcpy.app scrcpy.audio 2>/dev/null || echo mac)"
    case "$AUDIO" in
        device) EXTRA+=(--no-audio);;     # not captured: the device plays it
        both)   EXTRA+=(--audio-dup);;    # Mac and device (Android 13+)
    esac
    if [[ "$(defaults read com.genymobile.scrcpy.app scrcpy.screenOffOnStart 2>/dev/null)" == "1" ]]; then
        EXTRA+=(--turn-screen-off)
    fi
    if [[ ${#EXTRA[@]} -gt 0 ]]; then
        set -- "${EXTRA[@]}" "$@"
    fi
fi

# If scrcpy ends with an error right after starting, tell the user (the
# launcher becomes scrcpy through exec, so a background watcher does it)
APP_PID=$$
(
    START=$(date +%s)
    while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.5; done
    if (( $(date +%s) - START < 15 )) && grep -q '^ERROR' "$LOG" 2>/dev/null; then
        MSG="$(grep '^ERROR' "$LOG" | head -6 | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')"
        osascript -e "display dialog \"scrcpy could not start:\\n\\n$MSG\" buttons {\"OK\"} default button \"OK\" with icon caution with title \"scrcpy\"" >/dev/null 2>&1
    fi
) >/dev/null 2>&1 &
disown

exec "$DIR/scrcpy-bin" "$@" >"$LOG" 2>&1
LAUNCHER
chmod +x "$APP/Contents/MacOS/scrcpy"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>scrcpy</string>
    <key>CFBundleDisplayName</key><string>scrcpy</string>
    <key>CFBundleIdentifier</key><string>com.genymobile.scrcpy.app</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>scrcpy</string>
    <key>CFBundleIconFile</key><string>scrcpy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>scrcpy saves screenshots and screen recordings on the Desktop.</string>
</dict>
</plist>
PLIST

# Bundle the dynamic libraries (everything outside the system) so that the app
# does not depend on Homebrew
python3 - "$APP" <<'PY'
import os, subprocess, shutil, sys

app = sys.argv[1]
fw = os.path.join(app, "Contents/Frameworks")
binary = os.path.join(app, "Contents/MacOS/scrcpy-bin")
copied = {}  # real path -> bundled path

def deps(path):
    out = subprocess.check_output(["otool", "-L", path], text=True)
    return [l.split()[0] for l in out.splitlines()[1:]]

def resolve(dep, owner):
    if dep.startswith("@loader_path/"):
        return os.path.normpath(os.path.join(os.path.dirname(owner), dep[13:]))
    if dep.startswith("@rpath/"):
        for d in ("/opt/homebrew/lib", "/usr/local/lib",
                  os.path.dirname(owner)):
            p = os.path.join(d, dep[7:])
            if os.path.exists(p):
                return os.path.realpath(p)
        return None
    return os.path.realpath(dep) if os.path.exists(dep) else None

def is_system(dep):
    return dep.startswith(("/usr/lib/", "/System/"))

def process(path, owner_in_bundle):
    for dep in deps(path):
        if is_system(dep) or dep.startswith("@executable_path"):
            continue
        real = resolve(dep, path)
        if not real:
            print("warning: cannot resolve", dep, "for", path)
            continue
        name = os.path.basename(real)
        if real not in copied:
            dest = os.path.join(fw, name)
            shutil.copy(real, dest)
            os.chmod(dest, 0o755)
            copied[real] = dest
            subprocess.check_call(
                ["install_name_tool", "-id", "@executable_path/../Frameworks/" + name, dest])
            process(dest, dest)
        subprocess.check_call(
            ["install_name_tool", "-change", dep,
             "@executable_path/../Frameworks/" + name, owner_in_bundle],
            stderr=subprocess.DEVNULL)

process(binary, binary)
print("bundled", len(copied), "libraries")
PY

# Ad-hoc signature (required on Apple Silicon)
find "$APP/Contents/Frameworks" -type f -exec codesign --force --sign - {} \; 2>/dev/null
codesign --force --sign - "$APP/Contents/MacOS/adb" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/scrcpy-bin"
codesign --force --sign - "$APP"

# Zip to share (a .app is a folder: it cannot be attached as is)
ZIP="$ROOT/dist/scrcpy-$VERSION-macos-$(uname -m).zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Created $APP"
echo "Created $ZIP"
