# AppAudioController

A macOS menu-bar app for per-app audio control, built entirely on public macOS 14+ APIs.  
Per-app volume control, 10-band EQ, per-app audio routing, system volume, and more — no kext, no HAL plugin, no private SPI.

> **Requires macOS 14.4+** (uses `CATapDescription` + `AudioHardwareCreateProcessTap`, available from 14.2 but fully supported from 14.4).  
> **Apple Silicon and Intel** both supported.

---

## Screenshots

<table>
  <tr>
    <td align="center"><b>Control Panel</b><br/><sub>Per-app volume, EQ, and routing from the menu bar</sub></td>
    <td align="center"><b>Sources view</b><br/><sub>Favourites, paused apps, and other sources</sub></td>
    <td align="center"><b>Audio Devices window</b><br/><sub>Volume, balance, and sample rate for every device</sub></td>
  </tr>
  <tr>
    <td><img src="screenshots/control-panel.png" width="240"/></td>
    <td><img src="screenshots/control-panel-sources.png" width="240"/></td>
    <td><img src="screenshots/audio-devices-window.png" width="480"/></td>
  </tr>
</table>

---

## Features

| Feature | Description |
|---|---|
| **Per-app volume** | Independently control the volume of any running app (0 → 500%, with +40 dB EQ boost for quiet sources like calls) |
| **10-band parametric EQ** | Per-app equaliser — each source has its own curve |
| **Per-app audio routing** | Route Firefox to AirPods while Safari plays through MacBook Speakers, simultaneously |
| **Multiple sources at once** | Tap and control N apps independently at the same time |
| **System volume & mic** | Master output volume + microphone input gain with live keyboard-shortcut sync |
| **Audio Devices window** | Full device settings panel (volume, balance, sample rate, default device) — like a mini Audio MIDI Setup |
| **Smart auto-tap** | Starred (⭐) apps are automatically tapped when they start playing |
| **Favourites** | Pin apps for quick access and auto-tap |
| **Excluded sources** | Block specific apps from ever appearing in the list or being tapped |
| **Browser helper aliasing** | Chrome/Firefox renderer processes appear as "Google Chrome" / "Firefox" with correct icons |
| **Launch at Login** | One-click registration via `SMAppService` |
| **Dock pin toggle** | Optionally show the app in the Dock alongside the menu bar |

---

## Requirements

- macOS **14.4** or later
- Xcode Command Line Tools **or** Xcode (for `swift build`)
- No third-party dependencies beyond [`apple/swift-atomics`](https://github.com/apple/swift-atomics) (fetched automatically by SPM)

---

## Quick start

### First-time setup

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USERNAME/AppAudioController.git
cd AppAudioController

# 2. Create the .app bundle skeleton (once only)
APP=~/Desktop/AppAudioController.app
mkdir -p "$APP/Contents/MacOS"
cp Config/Info.plist "$APP/Contents/"

# 3. Build and install
swift build -c release
cp .build/release/AppAudioController "$APP/Contents/MacOS/"

# 4. Sign with the required audio-capture entitlement
codesign --force --deep \
  --entitlements Config/AppAudioController.entitlements \
  --sign - "$APP"

# 5. Launch
open "$APP"
```

On first launch macOS will show **"AppAudioController.app would like access to record your system audio"** — click **Allow**. This appears once per signing identity.

### Updating after code changes

```bash
# Kill the running instance, rebuild, re-sign, relaunch
killall AppAudioController 2>/dev/null
cd ~/Desktop/AppAudioController
swift build -c release
cp .build/release/AppAudioController ~/Desktop/AppAudioController.app/Contents/MacOS/
codesign --force --deep \
  --entitlements Config/AppAudioController.entitlements \
  --sign - ~/Desktop/AppAudioController.app
open ~/Desktop/AppAudioController.app
```

> **Why `codesign` after every build?**  
> The audio-capture entitlement (`com.apple.security.device.audio-input`) must be embedded in the binary for the tap IOProc to receive audio instead of silence. Ad-hoc signing (`--sign -`) is sufficient for development; use a Developer ID certificate for distribution.

---

## How it works

### Core architecture

The single most important constraint: **a single `AVAudioEngine` can only have one `AudioDeviceID`** — you cannot capture from app X and play to device Y inside one engine. The solution is a split architecture joined by a lock-free ring buffer:

```
CAPTURE (ProcessTap — outside AVAudioEngine)
  CATapDescription(stereoMixdownOfProcesses: [processObjectID])
      → AudioHardwareCreateProcessTap
      → AudioHardwareCreateAggregateDevice  (tap + output device as clock master)
      → AudioDeviceCreateIOProcIDWithBlock  ──writes──▶  AudioRingBuffer (SPSC, lock-free)

PLAYBACK (TapProcessingEngine — standalone AVAudioEngine)
  AudioRingBuffer ──reads──▶ AVAudioSourceNode
      → AVAudioUnitEQ (10-band parametric)
      → mainMixerNode  (per-app volume, up to +40 dB via globalGain)
      → outputNode     (bound to chosen device via kAudioOutputUnitProperty_CurrentDevice)
```

Each tapped source gets its **own independent** ProcessTap + ring + AVAudioEngine chain. Changing one source's output device rebuilds only that chain; all others keep running.

### Project layout

```
Sources/
├── App/
│   ├── AppAudioControllerApp.swift     — @main, MenuBarExtra + Audio Devices Window scenes
│   ├── MenuBarContentView.swift        — main control panel UI
│   └── DevicesSettingsView.swift       — Audio Devices window (mini Audio MIDI Setup)
├── Engine/
│   ├── AudioTapManager.swift           — @MainActor multi-session orchestrator
│   ├── ProcessTap.swift                — CATapDescription + aggregate device + IOProc
│   ├── TapProcessingEngine.swift       — AVAudioEngine playback chain (EQ, volume, routing)
│   └── AudioRingBuffer.swift           — lock-free SPSC Float32 ring buffer
├── System/
│   ├── AudioProcessEnumerator.swift    — HAL process objects → AudioProcessInfo
│   ├── AudioDeviceEnumerator.swift     — output devices → AudioOutputDevice
│   ├── SystemAudioManager.swift        — system output + mic volume with live listeners
│   └── AudioDeviceSettingsManager.swift — all-device settings (volume, balance, sample rate)
└── Support/
    ├── Models.swift                    — AudioProcessInfo, AudioOutputDevice, AudioStackError
    └── CoreAudioHelpers.swift          — typed wrappers over AudioObjectGetPropertyData
Config/
├── Info.plist                          — NSAudioCaptureUsageDescription, LSUIElement
└── AppAudioController.entitlements     — app-sandbox + device.audio-input
```

### Key implementation notes

**Process tapping (`ProcessTap.swift`)**  
- `CATapDescription.processes` takes **process-object `AudioObjectID`s**, NOT `pid_t`. Passing a raw PID produces a silent tap — the #1 bug in this API.  
- The aggregate device references the tap by its **UUID string** (`desc.uuid.uuidString`), not by the tap's `AudioObjectID`.  
- Teardown order is critical: Stop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap. Wrong order leaks objects or leaves apps muted.

**Ring buffer (`AudioRingBuffer.swift`)**  
- Lock-free SPSC using `ManagedAtomic` (acquire/release ordering). No locks, allocations, or ARC on realtime threads.  
- Handles both interleaved and non-interleaved (planar) `AudioBufferList` layouts — process taps frequently deliver non-interleaved Float32.

**Browser helper aliasing (`AudioProcessEnumerator.swift`)**  
- `com.google.Chrome.helper` / `org.mozilla.firefox.renderer` are renamed to their parent app's name + icon by looking up the parent bundle ID via `NSRunningApplication.runningApplications(withBundleIdentifier:)`.  
- `activationPolicy == .regular` filter removes system daemons and UI agents (Control Centre, loginwindow, PowerChime) without a hard-coded denylist.

**Volume amplification (`TapProcessingEngine.swift`)**  
- 0–100%: `mainMixerNode.outputVolume` (attenuation)  
- 100–500%: `AVAudioUnitEQ.globalGain` in dB (0 → +40 dB = 100× amplitude). `outputVolume > 1.0` is silently clamped by AVAudioEngine; `globalGain` is not.

---

## Permissions

| What | Why |
|---|---|
| `NSAudioCaptureUsageDescription` (Info.plist) | TCC consent string for `kTCCServiceAudioCapture`. Must be this key — **not** `NSMicrophoneUsageDescription` (different TCC class). |
| `com.apple.security.device.audio-input` (entitlements) | Without this, the tap is created successfully but the IOProc delivers **silence**. |
| App Sandbox enabled | Compatible with process taps using public APIs only. |

The consent dialog appears once. With ad-hoc signing (`--sign -`) it re-appears on every new build because the code hash changes. Use a stable Developer ID certificate to avoid this.

---

## Known limitations

- **Per-tab browser audio control** is not possible with public macOS APIs. Each browser tab playing audio appears as a separate process entry that can be controlled independently, but there is no public API to map a renderer PID to the tab title. The browser would need to expose this (e.g. via a browser extension + IPC).
- **Communication apps** (WhatsApp, Zoom, FaceTime) work best when added manually rather than auto-tapped. The `muteWhileTapped` re-routing can disrupt echo cancellation. Use the **System** volume slider for calls, or add the app manually and use the boost (100–500%) for quiet calls.
- **Ad-hoc signing** causes the audio-capture TCC consent to re-prompt on each new binary. This is a development-only limitation; a Developer ID certificate resolves it.

---

## References

- [Apple — Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio)
- [`insidegui/AudioCap`](https://github.com/insidegui/AudioCap) — canonical reference implementation for `CATapDescription` / `AudioHardwareCreateProcessTap`
- [`apple/swift-atomics`](https://github.com/apple/swift-atomics) — lock-free ring buffer atomics

---

## License

MIT
