//
//  AppAudioControllerApp.swift
//  AppAudioController
//
//  SwiftUI @main entry point for a menu-bar-only macOS app.
//
//  ROLE OF THIS FILE (per BUILD SPEC):
//  - Declare the `@main` App and configure it as a menu-bar-only agent using
//    `MenuBarExtra(menuBarExtraStyle: .window)` with an SF Symbol label.
//  - Own the single `AudioTapManager` (`@StateObject`) and inject it into the UI
//    (`MenuBarContentView`) via `.environmentObject`.
//  - Contain NO Core Audio logic whatsoever. All capture/playback/enumeration
//    lives in the Engine/* and System/* modules; this file is pure app wiring.
//
//  KEY CONSTRAINTS BAKED INTO THIS FILE:
//  - The whole tap stack is gated `@available(macOS 14.4, *)`. The tap symbols
//    technically link from 14.2, but Apple documents/supports 14.4 as the floor
//    (confirmed by AudioCap + Apple sample). Because `AudioTapManager` is itself
//    `@available(macOS 14.4, *)`, we cannot store it in a property of an
//    unconditionally-available `App` type, and we cannot put availability on a
//    stored `@StateObject` property directly. We therefore split the App body
//    into an availability-checked branch that builds the real UI, and a graceful
//    "unsupported OS" fallback for < 14.4. See `body` below for the WHY.
//  - Menu-bar-only: this is enforced by `LSUIElement=true` in Info.plist (NOT in
//    code). `MenuBarExtra` provides the status-bar item; there is no `WindowGroup`,
//    so the app presents no main window and (with LSUIElement) no Dock icon.
//  - Permissions are declared in Info.plist / entitlements, NOT here:
//      * Info.plist: LSUIElement=true, NSAudioCaptureUsageDescription (NOT
//        NSMicrophoneUsageDescription — process taps are the "Audio Capture" TCC
//        class, distinct from Microphone).
//      * Entitlements: com.apple.security.device.audio-input=true (required to
//        read from the tap; works under App Sandbox).
//    The OS shows the audio-capture consent prompt on first capture (public-API
//    path only — no private TCC SPI is used here).
//

import SwiftUI
import AppKit

// MARK: - App entry point

/// The application's single entry point.
///
/// This type is intentionally available on all OS versions (no `@available`
/// attribute) so it can satisfy the `App` protocol's `@main` requirement on any
/// SDK/runtime. The version gating happens *inside* the scene body, where we
/// branch on `macOS 14.4` and only then touch the tap-dependent stack.
@main
struct AppAudioControllerApp: App {

    /// Holds the manager's lifetime. We cannot annotate a `@StateObject` property
    /// with `@available`, and `AudioTapManager` is `@available(macOS 14.4, *)`,
    /// so we cannot store an `AudioTapManager` here directly on all OS versions.
    ///
    /// WHY this wrapper: `MenuBarContentScene` is itself `@available(macOS 14.4, *)`
    /// and owns the `@StateObject var manager: AudioTapManager`. SwiftUI's
    /// `@StateObject` must live on a `View`/`App`/`Scene` whose availability
    /// matches the object's, so the manager's storage is pushed down into that
    /// version-gated scene. On macOS < 14.4 we never instantiate it at all.
    /// Shared device settings manager — available to both the menu bar and the
    /// Audio Devices window without needing macOS 14.4.
    @StateObject private var deviceSettings = AudioDeviceSettingsManager()

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            Image(systemName: "slider.horizontal.2.square.on.square")
                .accessibilityLabel("App Audio Controller")
        }
        .menuBarExtraStyle(.window)

        // Audio Devices settings window (opened via openWindow(id:) from the UI).
        Window("Audio Devices", id: "audio-devices") {
            DevicesSettingsView()
                .environmentObject(deviceSettings)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 700, height: 460)
    }

    /// Builds the inner content of the menu bar window, branching on OS support.
    ///
    /// We return an opaque `some View` and switch on availability internally so
    /// the unsupported-OS path produces a small, self-contained explanatory view
    /// rather than crashing or showing an empty popover.
    @ViewBuilder
    private var menuContent: some View {
        if #available(macOS 14.4, *) {
            // Hand off to a version-gated container that actually owns the
            // `@StateObject AudioTapManager` and presents `MenuBarContentView`.
            MenuBarRootView()
                .environmentObject(deviceSettings)
        } else {
            // Graceful fallback for macOS 13.0..<14.4: the Core Audio Process Tap
            // API is unavailable, so there is no manager to construct. Surface a
            // clear message instead of a broken UI.
            UnsupportedOSView()
        }
    }
}

// MARK: - Version-gated root (owns the manager)

/// The real menu-bar UI root. This is the lowest point at which we can legally
/// declare `@StateObject var manager: AudioTapManager`, because the property's
/// type is `@available(macOS 14.4, *)` and so is this view.
///
/// It instantiates the manager exactly once (via `@StateObject`'s autoclosure,
/// which runs a single time for the view's lifetime), performs an initial list
/// refresh on appear, and injects the manager into `MenuBarContentView` through
/// the environment — matching the spec's `@EnvironmentObject var manager` contract.
@available(macOS 14.4, *)
private struct MenuBarRootView: View {

    /// SwiftUI creates and retains this `AudioTapManager` for the lifetime of the
    /// menu bar window. `@StateObject` (not `@ObservedObject`) is required so the
    /// instance survives view re-evaluations and remains the single source of
    /// truth for selection, device/process lists, and the live control surface.
    ///
    /// `AudioTapManager` is `@MainActor` per the spec; constructing it here on the
    /// main thread (SwiftUI builds views on the main actor) is safe.
    @StateObject private var manager     = AudioTapManager()
    @StateObject private var systemAudio = SystemAudioManager()
    @EnvironmentObject private var deviceSettings: AudioDeviceSettingsManager

    var body: some View {
        MenuBarContentView()
            .environmentObject(manager)
            .environmentObject(systemAudio)
            .environmentObject(deviceSettings)
            .task {
                manager.refreshProcesses()
                manager.refreshDevices()
                // Restore the Dock-pin preference from the previous session.
                // LSUIElement=true starts the app as .accessory (no Dock icon);
                // if the user had pinned it before, switch back to .regular now.
                if UserDefaults.standard.bool(forKey: "dockPinned") {
                    NSApp.setActivationPolicy(.regular)
                }
            }
    }
}

// MARK: - Unsupported OS fallback

/// Shown on macOS versions older than 14.4, where `AudioHardwareCreateProcessTap`
/// and `CATapDescription` (the Core Audio Process Tap API this app is built on)
/// are not usable. Keeps the app launchable and explains the requirement instead
/// of presenting a non-functional control surface.
private struct UnsupportedOSView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unsupported macOS version", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("App Audio Controller requires macOS 14.4 or later, which is when "
                 + "the Core Audio Process Tap API became available for per-app "
                 + "audio capture and routing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 320)
    }
}
