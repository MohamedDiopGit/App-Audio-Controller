//  MenuBarContentView.swift
//  AppAudioController
//
//  Multi-source control panel. Shows all audio-connected apps (running + paused).
//  Each app can be independently tapped with its own volume and 10-band EQ.
//

import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

// MARK: - Scroll content height measurement

private struct ScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Root content view

@available(macOS 14.4, *)
struct MenuBarContentView: View {

    @EnvironmentObject private var manager:     AudioTapManager
    @EnvironmentObject private var systemAudio: SystemAudioManager
    @State private var addError: String?
    @State private var showAllAvailable = false

    /// Natural height of the scrollable content (outputSection + sourcesSection).
    /// Starts at a sane default so the window appears immediately; updated after
    /// the first layout pass via PreferenceKey.
    @State private var scrollContentHeight: CGFloat = 300

    private static let previewCount = 3

    // Estimated pixel heights of the two sticky sections so we can compute the
    // total window height without measuring them dynamically.
    // header (~36 content) + 12+12 padding + 1 divider ≈ 61
    private let stickyTopHeight:    CGFloat = 61
    // 1 divider + footer (~30 content) + 12+12 padding ≈ 55
    private let stickyBottomHeight: CGFloat = 55

    private var windowHeight: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        return min(scrollContentHeight + stickyTopHeight + stickyBottomHeight, screen)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                systemSection
                Divider()
                outputSection
                Divider()
                sourcesSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            // Measure the natural height of the scrollable content.
            // Guard h > 50 so a zero emitted on the very first layout pass
            // (before the ScrollView has measured its content) is ignored.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollContentHeightKey.self,
                        value: geo.size.height
                    )
                }
            )
        }
        .onPreferenceChange(ScrollContentHeightKey.self) { h in
            guard h > 50 else { return }
            scrollContentHeight = h
        }
        // Sticky header — always visible above the scroll area.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                Divider()
            }
            .background(.regularMaterial)
        }
        // Sticky footer — always visible below the scroll area.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .background(.regularMaterial)
        }
        // Assign a concrete height. The ScrollView will scroll when the scrollable
        // content is taller than (windowHeight - stickyTop - stickyBottom).
        .frame(width: 340, height: windowHeight)
        .animation(.easeInOut(duration: 0.15), value: windowHeight)
        .onAppear {
            manager.refreshProcesses()
            manager.refreshDevices()
            systemAudio.refresh()
            showAllAvailable = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Audio Controller")
                .font(.headline)
            Spacer()
            sessionCountBadge
        }
    }

    private var sessionCountBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(manager.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            let n = manager.sessions.count
            Text(n == 0 ? "Stopped" : "\(n) running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - System volume section

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("System", systemImage: "macbook")
                .font(.subheadline.weight(.medium))

            // ── Output / speaker volume ───────────────────────────────────
            HStack(spacing: 8) {
                // Tap to mute / unmute
                Button { systemAudio.toggleOutputMute() } label: {
                    Image(systemName: systemAudio.isOutputMuted
                          ? "speaker.slash.fill"
                          : outputVolumeSymbol)
                        .font(.callout)
                        .foregroundStyle(systemAudio.isOutputMuted ? .red : .primary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(systemAudio.isOutputMuted ? "Unmute" : "Mute")

                Slider(value: outputVolumeBinding, in: 0...1)
                    .opacity(systemAudio.isOutputMuted ? 0.4 : 1)

                Text("\(Int(systemAudio.outputVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            // ── Microphone / input volume ─────────────────────────────────
            if systemAudio.hasInputVolumeControl {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    Slider(value: inputVolumeBinding, in: 0...1)

                    Text("\(Int(systemAudio.inputVolume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }

    private var outputVolumeSymbol: String {
        switch systemAudio.outputVolume {
        case ..<0.001: return "speaker.fill"
        case ..<0.34:  return "speaker.wave.1.fill"
        case ..<0.67:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private var outputVolumeBinding: Binding<Float> {
        Binding(get: { systemAudio.outputVolume },
                set: { systemAudio.setOutputVolume($0) })
    }

    private var inputVolumeBinding: Binding<Float> {
        Binding(get: { systemAudio.inputVolume },
                set: { systemAudio.setInputVolume($0) })
    }

    // MARK: - Output device (shared by all sessions)

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Output Device", systemImage: "hifispeaker")
                    .font(.subheadline.weight(.medium))
                Spacer()
                refreshButton(help: "Refresh output devices") { manager.refreshDevices() }
            }
            Picker("Output Device", selection: selectedDeviceBinding) {
                Text("System Default").tag(AudioOutputDevice?.none)
                ForEach(manager.outputDevices) { device in
                    Text(device.name).tag(AudioOutputDevice?.some(device))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text("Default for new sources. Each source can be routed independently above.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sources (active sessions + available to add)

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Sources", systemImage: "app.badge")
                    .font(.subheadline.weight(.medium))
                Spacer()
                refreshButton(help: "Refresh the app list") { manager.refreshProcesses() }
            }

            // Active sessions — each gets its own volume + EQ controls.
            if !manager.sessions.isEmpty {
                ForEach(manager.sessions) { session in
                    ActiveSessionRow(sessionID: session.id)
                        .environmentObject(manager)
                }
            }

            // ── Favorites (always fully visible, no collapse) ────────────────
            if !favoriteAvailableProcesses.isEmpty {
                sectionLabel("Favorites", icon: "star.fill", color: .yellow)
                ForEach(favoriteAvailableProcesses) { process in
                    availableRow(process)
                }
            }

            // ── Other available sources (collapsed by default) ────────────
            if !regularAvailableProcesses.isEmpty {
                sectionLabel(
                    favoriteAvailableProcesses.isEmpty && manager.sessions.isEmpty
                        ? "Add source" : "Other sources",
                    icon: "plus.circle",
                    color: .secondary
                )

                let visible = showAllAvailable
                    ? regularAvailableProcesses
                    : Array(regularAvailableProcesses.prefix(MenuBarContentView.previewCount))

                ForEach(visible) { process in availableRow(process) }

                if regularAvailableProcesses.count > MenuBarContentView.previewCount {
                    let hidden = regularAvailableProcesses.count - MenuBarContentView.previewCount
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showAllAvailable.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllAvailable ? "Show less" : "Show \(hidden) more…")
                                .font(.caption)
                            Image(systemName: showAllAvailable ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }

            if manager.processes.isEmpty && manager.excludedProcesses.isEmpty {
                Text("No apps with audio found. Try refreshing or open an app that plays audio.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = addError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── Excluded sources (collapsed by default) ───────────────
            if !manager.excludedProcesses.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showExcluded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("Excluded (\(manager.excludedProcesses.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: showExcluded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)

                if showExcluded {
                    ForEach(manager.excludedProcesses) { process in
                        ExcludedProcessRow(process: process)
                            .environmentObject(manager)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Derived process lists

    private var activeIDs: Set<AudioObjectID> { Set(manager.sessions.map(\.id)) }

    /// Favorited processes not currently in an active session.
    private var favoriteAvailableProcesses: [AudioProcessInfo] {
        manager.processes.filter { !activeIDs.contains($0.id) && manager.isFavorite($0) }
    }

    /// Non-favorited processes not currently in an active session.
    private var regularAvailableProcesses: [AudioProcessInfo] {
        manager.processes.filter { !activeIDs.contains($0.id) && !manager.isFavorite($0) }
    }

    // MARK: - Reusable row / label builders

    @ViewBuilder
    private func availableRow(_ process: AudioProcessInfo) -> some View {
        AvailableProcessRow(process: process, addError: $addError) { p in
            do { addError = nil; try manager.addSession(for: p) }
            catch { addError = describeError(error) }
        }
        .environmentObject(manager)
    }

    @ViewBuilder
    private func sectionLabel(_ title: String,
                               icon: String,
                               color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    // MARK: - Footer

    @State private var showExcluded = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("dockPinned") private var dockPinned: Bool = false
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    private var footer: some View {
        HStack(spacing: 8) {
            if manager.isRunning {
                Button("Stop All", role: .destructive) {
                    manager.stopAllSessions()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            // Audio Devices settings window
            Button {
                openWindow(id: "audio-devices")
                // LSUIElement apps don't activate automatically — bring to front explicitly.
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "hifispeaker.2")
            }
            .buttonStyle(.borderless)
            .help("Audio Devices settings")

            // Launch at Login toggle
            Button { toggleLaunchAtLogin() } label: {
                Image(systemName: launchAtLogin ? "arrow.up.circle.fill" : "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .help(launchAtLogin ? "Don't launch at login" : "Launch at login")

            // Dock-pin toggle
            Button {
                dockPinned.toggle()
                NSApp.setActivationPolicy(dockPinned ? .regular : .accessory)
            } label: {
                Image(systemName: dockPinned ? "dock.arrow.down.rectangle" : "dock.rectangle")
            }
            .buttonStyle(.borderless)
            .help(dockPinned ? "Unpin from Dock" : "Pin to Dock")

            Button {
                manager.stopAllSessions()
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Silently ignore — e.g. permission denied in some sandbox configs.
        }
        // Re-read the authoritative state from SMAppService rather than
        // flipping the bool ourselves, so the icon always reflects reality.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Helpers

    private var selectedDeviceBinding: Binding<AudioOutputDevice?> {
        Binding(get: { manager.selectedOutputDevice },
                set: { manager.selectedOutputDevice = $0 })
    }

    @ViewBuilder
    private func refreshButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func describeError(_ error: Error) -> String {
        guard let e = error as? AudioStackError else { return error.localizedDescription }
        switch e {
        case let .osStatus(status, ctx): return "Audio error (\(status)) in \(ctx)."
        case let .processNotFound(pid):  return "App (pid \(pid)) is no longer available."
        case let .deviceNotFound(uid):   return "Output device '\(uid)' unavailable."
        case .invalidTapFormat:          return "Unsupported audio format from this app."
        case .unsupportedOS:             return "Requires macOS 14.4 or later."
        case let .engineStartFailed(e):  return "Engine failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Active session row (one per tapped app)

@available(macOS 14.4, *)
private struct ActiveSessionRow: View {
    @EnvironmentObject var manager: AudioTapManager
    let sessionID: AudioObjectID

    // Local EQ expansion toggle (collapsed by default to save space).
    @State private var eqExpanded: Bool = false

    private var session: TapSessionState? {
        manager.sessions.first { $0.id == sessionID }
    }

    var body: some View {
        guard let session else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                // ── App name + favourite + remove ────────────────────────
                HStack(spacing: 6) {
                    appIcon(session.process.icon)
                    Text(session.process.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    // Star to mark/unmark as favourite
                    Button { manager.toggleFavorite(for: session.process) } label: {
                        Image(systemName: manager.isFavorite(session.process)
                              ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(manager.isFavorite(session.process)
                                             ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(manager.isFavorite(session.process)
                          ? "Remove from Favorites" : "Add to Favorites")

                    Button {
                        manager.removeSession(sessionID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop tapping \(session.process.name)")
                }

                // ── Output device for this session ───────────────────────
                HStack(spacing: 6) {
                    Image(systemName: "hifispeaker")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Picker("", selection: outputDeviceBinding(for: session)) {
                        ForEach(manager.outputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.caption)
                }

                // ── Volume slider ────────────────────────────────────────
                HStack(spacing: 6) {
                    Image(systemName: volumeSymbol(session.volume))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Slider(value: volumeBinding(for: session), in: 0...5)
                    Text(volumeLabel(session.volume))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(session.volume > 1.0 ? .orange : .secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                // ── EQ toggle + expand ───────────────────────────────────
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { eqExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.vertical.3")
                                .font(.caption)
                            Text("EQ")
                                .font(.caption)
                            Image(systemName: eqExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8))
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                    Toggle("", isOn: eqEnabledBinding(for: session))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.75, anchor: .leading)
                        .frame(height: 20)
                }

                if eqExpanded {
                    eqBandsView(for: session)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    Button("Reset EQ") { manager.resetEQ(for: sessionID) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        )
    }

    // ── EQ bands ─────────────────────────────────────────────────────────

    @ViewBuilder
    private func eqBandsView(for session: TapSessionState) -> some View {
        let frequencies = TapProcessingEngine.bandCenterFrequencies
        let bandCount = min(frequencies.count, session.bandGains.count)
        let gainRange: ClosedRange<Float> = -12.0...12.0

        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<bandCount, id: \.self) { index in
                    VStack(spacing: 2) {
                        Slider(value: bandGainBinding(index: index, session: session),
                               in: gainRange)
                            .frame(width: 90)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 22, height: 90)
                            .disabled(!session.eqEnabled)
                            .opacity(session.eqEnabled ? 1 : 0.4)
                            .help(bandTooltip(index: index, session: session,
                                             frequency: frequencies[index]))
                        Text(freqLabel(frequencies[index]))
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            Text("Gain ±12 dB")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    @ViewBuilder
    private func appIcon(_ icon: NSImage?) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 16, height: 16)
        }
    }

    private func volumeSymbol(_ v: Float) -> String {
        switch v {
        case ..<0.001: return "speaker.slash.fill"
        case ..<0.34:  return "speaker.wave.1.fill"
        case ..<0.67:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    /// Display label for the volume slider.
    /// Below 100%: plain percentage.
    /// Above 100%: percentage + approximate dB boost so the user knows how much amplification they're applying.
    private func volumeLabel(_ v: Float) -> String {
        let pct = Int(v * 100)
        if v <= 1.01 { return "\(pct)%" }
        let dB = Int((v - 1.0) * 10.0)
        return "+\(dB)dB"
    }

    private func freqLabel(_ hz: Float) -> String {
        hz >= 1000
            ? (hz / 1000 == (hz / 1000).rounded() ? "\(Int(hz / 1000))k" : String(format: "%.1fk", hz / 1000))
            : "\(Int(hz))"
    }

    private func bandTooltip(index: Int, session: TapSessionState, frequency: Float) -> String {
        let gain = index < session.bandGains.count ? session.bandGains[index] : 0
        return "\(freqLabel(frequency)): \(String(format: "%+.1f", gain)) dB"
    }

    // ── Bindings ──────────────────────────────────────────────────────────

    /// Routes the session to whichever device the picker selects.
    /// Uses device UID as the stable tag (IDs are reassigned across reboots).
    private func outputDeviceBinding(for session: TapSessionState) -> Binding<String> {
        Binding(
            get: { session.outputDevice.uid },
            set: { uid in
                guard let device = manager.outputDevices.first(where: { $0.uid == uid }) else { return }
                manager.setOutputDevice(device, for: sessionID)
            }
        )
    }

    private func volumeBinding(for session: TapSessionState) -> Binding<Float> {
        Binding(get: { session.volume },
                set: { manager.setVolume($0, for: sessionID) })
    }

    private func eqEnabledBinding(for session: TapSessionState) -> Binding<Bool> {
        Binding(get: { session.eqEnabled },
                set: { manager.setEQEnabled($0, for: sessionID) })
    }

    private func bandGainBinding(index: Int, session: TapSessionState) -> Binding<Float> {
        Binding(
            get: { index < session.bandGains.count ? session.bandGains[index] : 0 },
            set: { manager.setBandGain(index, dB: $0, for: sessionID) }
        )
    }
}

// MARK: - Available process row (tap "+" to add a session)

@available(macOS 14.4, *)
private struct AvailableProcessRow: View {
    @EnvironmentObject var manager: AudioTapManager
    let process: AudioProcessInfo
    @Binding var addError: String?
    let onAdd: (AudioProcessInfo) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            Text(process.name)
                .font(.callout)
                .lineLimit(1)
            if !process.isRunningOutput {
                Text("paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer()
            // Exclude — hides the app from the list and prevents auto-tap
            Button { manager.toggleExcluded(for: process) } label: {
                Image(systemName: "circle.slash")
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Exclude \(process.name) from sources")

            // Star to toggle favourite
            Button { manager.toggleFavorite(for: process) } label: {
                Image(systemName: manager.isFavorite(process) ? "star.fill" : "star")
                    .foregroundStyle(manager.isFavorite(process) ? Color.yellow : Color.secondary.opacity(0.4))
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help(manager.isFavorite(process) ? "Remove from Favorites" : "Add to Favorites")

            Button { onAdd(process) } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Start controlling \(process.name)")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Excluded process row (shown in the collapsed "Excluded" section)

@available(macOS 14.4, *)
private struct ExcludedProcessRow: View {
    @EnvironmentObject var manager: AudioTapManager
    let process: AudioProcessInfo

    var body: some View {
        HStack(spacing: 6) {
            if let icon = process.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    .opacity(0.5)
            } else {
                Image(systemName: "app.dashed").frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            Text(process.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            // Un-exclude button
            Button {
                manager.toggleExcluded(for: process)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 9))
                    Text("Restore")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Restore \(process.name) to the sources list")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.4, *)
#Preview("Menu Bar Content") {
    MenuBarContentView()
        .environmentObject(AudioTapManager())
        .environmentObject(SystemAudioManager())
}
#endif
