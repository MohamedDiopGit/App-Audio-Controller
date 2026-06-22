#!/bin/bash
set -e

# 1. Clone the repository
APP_NAME="App-Audio-Controller"

# 2. Create the application bundle
APP_PATH="$HOME/Desktop/${APP_NAME}.app"

mkdir -p "$APP_PATH/Contents/MacOS"

cp Config/Info.plist "$APP_PATH/Contents/Info.plist"

# 3. Build the application
swift build -c release

# 4. Install the executable
cp ".build/release/AppAudioController" \
   "$APP_PATH/Contents/MacOS/AppAudioController"

# 5. Sign the application
codesign \
  --force \
  --deep \
  --entitlements Config/AppAudioController.entitlements \
  --sign - \
  "$APP_PATH"

# 6. Launch the application
open "$APP_PATH"