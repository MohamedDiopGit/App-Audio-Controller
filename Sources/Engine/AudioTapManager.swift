//  AudioTapManager.swift
//  Engine
//
//  Multi-session @MainActor coordinator. Every tapped app gets its OWN independent
//  ProcessTap → AudioRingBuffer → TapProcessingEngine chain. Each session also has
//  its OWN output device, enabling per-app audio routing:
//
//    process A  → ProcessTap-A → ring-A → TapProcessingEngine-A (vol, EQ) → AirPods
//    process B  → ProcessTap-B → ring-B → TapProcessingEngine-B (vol, EQ) → MacBook Speakers
//    process C  → ProcessTap-C → ring-C → TapProcessingEngine-C (vol, EQ) → HDMI Monitor
//

import Foundation
import CoreAudio
import AVFoundation
import Combine
import os

// MARK: - Per-session published state (value type; @Published array triggers UI updates)

/// Lightweight published state for one active tap session.
/// This is a value type — the manager owns the array; mutations publish automatically.
@available(macOS 14.4, *)
struct TapSessionState: Identifiable {
    let id: AudioObjectID
    let process: AudioProcessInfo

    var volume: Float = 1.0
    var bandGains: [Float]
    var eqEnabled: Bool = true

    /// The output device this session is routed to. Each session can send audio
    /// to a DIFFERENT device (AirPods, HDMI monitor, MacBook speakers, etc.).
    var outputDevice: AudioOutputDevice

    init(process: AudioProcessInfo, outputDevice: AudioOutputDevice) {
        self.id = process.id
        self.process = process
        self.outputDevice = outputDevice
        self.bandGains = Array(
            repeating: 0,
            count: TapProcessingEngine.bandCenterFrequencies.count
        )
    }
}

// MARK: - Manager

@available(macOS 14.4, *)
@MainActor
final class AudioTapManager: ObservableObject {

    // MARK: - Published state the UI binds to

    /// All audio-connected user processes (running + paused). Updated by refreshProcesses().
    @Published var processes: [AudioProcessInfo] = []
    /// Enumerated hardware output devices.
    @Published var outputDevices: [AudioOutputDevice] = []
    /// Chosen output device, shared by all sessions. Applied to each new session on add.
    @Published var selectedOutputDevice: AudioOutputDevice?
    /// Active sessions in insertion order. SwiftUI iterates this directly.
    @Published var sessions: [TapSessionState] = []
    /// Last error from any session operation — shown in the UI.
    @Published var lastError: AudioStackError?

    // MARK: - Internal per-session audio stack (not published)

    private struct SessionEngine {
        let tap: ProcessTap
        let ring: AudioRingBuffer
        let engine: TapProcessingEngine
    }

    /// Keyed by process-object AudioObjectID (same as TapSessionState.id).
    private var engines: [AudioObjectID: SessionEngine] = [:]

    private let log = Logger(subsystem: "AppAudioController", category: "AudioTapManager")

    // MARK: - Favorites (persisted by bundle ID across launches)

    @Published private(set) var favoriteBundleIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "favoriteSourceIDs") ?? [])
    }()
    private static let favoritesDefaultsKey = "favoriteSourceIDs"

    func toggleFavorite(for process: AudioProcessInfo) {
        let key = process.bundleID ?? process.name
        if favoriteBundleIDs.contains(key) { favoriteBundleIDs.remove(key) }
        else { favoriteBundleIDs.insert(key) }
        UserDefaults.standard.set(Array(favoriteBundleIDs), forKey: Self.favoritesDefaultsKey)
    }
    func isFavorite(_ process: AudioProcessInfo) -> Bool {
        favoriteBundleIDs.contains(process.bundleID ?? process.name)
    }

    // MARK: - Excluded sources (persisted by bundle ID across launches)

    /// Apps the user has explicitly blocked from auto-tap and from the visible list.
    @Published private(set) var excludedBundleIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "excludedSourceIDs") ?? [])
    }()
    private static let excludedDefaultsKey = "excludedSourceIDs"

    /// Excluded apps that are currently registered with Core Audio — shown in the
    /// "Excluded" section so the user can un-exclude them.
    @Published var excludedProcesses: [AudioProcessInfo] = []

    func toggleExcluded(for process: AudioProcessInfo) {
        let key = process.bundleID ?? process.name
        if excludedBundleIDs.contains(key) {
            excludedBundleIDs.remove(key)
        } else {
            excludedBundleIDs.insert(key)
            // If currently tapped, stop it immediately.
            if engines[process.id] != nil { removeSession(process.id) }
        }
        UserDefaults.standard.set(Array(excludedBundleIDs), forKey: Self.excludedDefaultsKey)
        // Repopulate both the visible and excluded lists.
        refreshProcesses()
    }
    func isExcluded(_ process: AudioProcessInfo) -> Bool {
        excludedBundleIDs.contains(process.bundleID ?? process.name)
    }

    // MARK: - Derived

    var isRunning: Bool { !sessions.isEmpty }

    // MARK: - Init

    init() {
        refreshProcesses()
        refreshDevices()
    }

    // MARK: - Enumeration

    func refreshProcesses() {
        do {
            // Use allProcesses() so paused apps appear too. Require an icon:
            // real user-facing apps always have one; Apple system daemons and
            // background XPC helpers never do — filtering by icon removes the
            // noise (com.apple.audiomxd, com.apple.avconferenced, etc.) without
            // needing an explicit denylist. Also exclude our own process.
            let all = try AudioProcessEnumerator.allProcesses()
            let selfBundleID = Bundle.main.bundleIdentifier
            // Two conditions (belt-and-suspenders):
            // 1. activationPolicy == .regular: only real Dock apps pass. System
            //    daemons (loginwindow, audiomxd, PowerChime…) are .prohibited;
            //    system UI agents (Control Centre) are .accessory. Chrome/Firefox
            //    helpers inherit .regular from their parent via the aliasing step.
            //    Daemons with no NSRunningApplication entry default to .prohibited.
            // 2. icon != nil: a second guard for any daemon that somehow slips
            //    through with a non-nil activationPolicy but no user-visible icon.
            // Eligible = real user-facing apps, not ourselves.
            let eligible = all.filter {
                $0.activationPolicy == .regular
                    && $0.icon != nil
                    && $0.bundleID != selfBundleID
            }
            // Split into visible (shown in the sources list) and excluded (shown in
            // the collapsed "Excluded" section so the user can un-exclude them).
            processes         = eligible.filter { !isExcluded($0) }
            excludedProcesses = eligible.filter {  isExcluded($0) }
            // Auto-tap only processes the user has explicitly starred as Favorites.
            // Tapping all active processes aggressively (the old behaviour) caused
            // communication apps (WhatsApp, FaceTime, Zoom…) to lose audio quality:
            // muteWhileTapped mutes the app's direct hardware output and re-routes
            // through our AVAudioEngine, which adds latency and confuses echo
            // cancellation. By limiting auto-tap to Favorites the user controls
            // exactly which apps are intercepted; everything else is left untouched.
            // Auto-tap only processes the user has explicitly starred as Favorites.
            // Tapping all active processes aggressively (the old behaviour) caused
            // communication apps (WhatsApp, FaceTime, Zoom…) to lose audio quality:
            // muteWhileTapped mutes the app's direct hardware output and re-routes
            // through our AVAudioEngine, which adds latency and confuses echo
            // cancellation. By limiting auto-tap to Favorites the user controls
            // exactly which apps are intercepted; everything else is left untouched.
            for process in processes
            where process.isRunningOutput
               && engines[process.id] == nil
               && isFavorite(process) {
                try? addSession(for: process)
            }
        } catch {
            surface(error, context: "refreshProcesses")
        }
    }

    func refreshDevices() {
        let fresh = AudioDeviceEnumerator.outputDevices()
        outputDevices = fresh
        if let current = selectedOutputDevice {
            selectedOutputDevice = fresh.first { $0 == current }
        }
        if selectedOutputDevice == nil {
            selectedOutputDevice = AudioDeviceEnumerator.defaultOutputDevice() ?? fresh.first
        }
    }

    // MARK: - Session lifecycle

    /// Start a new tap session for `process` routed to `outputDevice`.
    /// Pass `nil` for `outputDevice` to use the current `selectedOutputDevice`.
    /// No-op if `process` is already tapped.
    func addSession(for process: AudioProcessInfo,
                    outputDevice: AudioOutputDevice? = nil) throws {
        guard engines[process.id] == nil else { return }

        guard let device = outputDevice
                ?? selectedOutputDevice
                ?? AudioDeviceEnumerator.defaultOutputDevice() else {
            let err = AudioStackError.deviceNotFound(uid: "<none>")
            surface(err, context: "addSession: no output device")
            throw err
        }
        // Keep selectedOutputDevice in sync for future sessions.
        if outputDevice == nil { selectedOutputDevice = device }

        do {
            let sess = try buildEngine(for: process, using: device)
            engines[process.id] = sess
            sessions.append(TapSessionState(process: process, outputDevice: device))
            lastError = nil
            log.info("Session added: \(process.name, privacy: .public) → \(device.name, privacy: .public)")
        } catch let e as AudioStackError {
            surface(e, context: "addSession(\(process.name))")
            throw e
        } catch {
            let wrapped = AudioStackError.engineStartFailed(underlying: error)
            surface(wrapped, context: "addSession(\(process.name))")
            throw wrapped
        }
    }

    /// Redirect an existing session to a different output device.
    /// Tears down and rebuilds just that session's engine; all other sessions
    /// are unaffected. Preserves volume, EQ gains, and EQ enabled state.
    func setOutputDevice(_ device: AudioOutputDevice, for id: AudioObjectID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }),
              sessions[idx].outputDevice.uid != device.uid else { return }

        let process   = sessions[idx].process
        let volume    = sessions[idx].volume
        let gains     = sessions[idx].bandGains
        let eqEnabled = sessions[idx].eqEnabled

        tearDownSession(id)

        do {
            let sess = try buildEngine(for: process, using: device)
            engines[id] = sess
            // Restore control surface on the new engine.
            sess.engine.setVolume(volume)
            for (i, gain) in gains.enumerated() where eqEnabled {
                sess.engine.setBandGain(i, dB: gain)
            }
            sessions[idx].outputDevice = device
            sessions[idx].volume    = volume
            sessions[idx].bandGains = gains
            sessions[idx].eqEnabled = eqEnabled
            log.info("Redirected \(process.name, privacy: .public) → \(device.name, privacy: .public)")
        } catch {
            surface(error, context: "setOutputDevice(\(device.name))")
            // Session is now engine-less — remove it to avoid a zombie state.
            sessions.removeAll { $0.id == id }
        }
    }

    /// Stop and remove the session for the given process-object id.
    func removeSession(_ id: AudioObjectID) {
        tearDownSession(id)
        sessions.removeAll { $0.id == id }
        log.info("Session removed: id=\(id)")
    }

    /// Stop and remove all active sessions.
    func stopAllSessions() {
        for id in engines.keys { tearDownSession(id) }
        sessions.removeAll()
        log.info("All sessions stopped")
    }

    // MARK: - Live control surface (per session)

    func setVolume(_ v: Float, for id: AudioObjectID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(v, 0), 5)   // up to 500% (+40 dB) for amplification
        sessions[idx].volume = clamped
        engines[id]?.engine.setVolume(clamped)
    }

    /// Update a single EQ band gain. Stored in state regardless of eqEnabled;
    /// only forwarded to the engine when EQ is on.
    func setBandGain(_ index: Int, dB: Float, for id: AudioObjectID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }),
              index < sessions[idx].bandGains.count else { return }
        let clamped = min(max(dB, -96), 24)
        sessions[idx].bandGains[index] = clamped
        if sessions[idx].eqEnabled {
            engines[id]?.engine.setBandGain(index, dB: clamped)
        }
    }

    /// Toggle EQ bypass for a session. Gains are preserved in state; disabling
    /// zeroes the engine bands, enabling re-applies the stored gains.
    func setEQEnabled(_ enabled: Bool, for id: AudioObjectID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].eqEnabled = enabled
        if enabled {
            for (i, gain) in sessions[idx].bandGains.enumerated() {
                engines[id]?.engine.setBandGain(i, dB: gain)
            }
        } else {
            for i in sessions[idx].bandGains.indices {
                engines[id]?.engine.setBandGain(i, dB: 0)
            }
        }
    }

    /// Reset all EQ bands to 0 dB for a session.
    func resetEQ(for id: AudioObjectID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        for i in sessions[idx].bandGains.indices {
            sessions[idx].bandGains[i] = 0
            if sessions[idx].eqEnabled {
                engines[id]?.engine.setBandGain(i, dB: 0)
            }
        }
    }

    // MARK: - Private helpers

    /// Build and start a complete capture + playback chain for `process` routed to `device`.
    /// Extracted so both `addSession` and `setOutputDevice` share identical wiring logic.
    private func buildEngine(for process: AudioProcessInfo,
                              using device: AudioOutputDevice) throws -> SessionEngine {
        let tap = try ProcessTap(process: process,
                                 outputDeviceUID: device.uid,
                                 muteWhileTapped: true)
        let tapASBD = tap.streamFormat
        try AudioTapManager.validateTapFormat(tapASBD)

        let channels = AVAudioChannelCount(tapASBD.mChannelsPerFrame)
        let sampleRate = tapASBD.mSampleRate
        let ringFormat = AudioTapManager.makeInterleavedFloat32Format(
            sampleRate: sampleRate, channels: channels)
        let capacityFrames = max(Int(sampleRate * 2.0), 8192)
        let ring = AudioRingBuffer(format: ringFormat, capacityFrames: capacityFrames)

        let playback = try TapProcessingEngine(tapFormat: tapASBD,
                                               outputDeviceID: device.id,
                                               ringBuffer: ring)
        try tap.start(writingTo: ring)
        do {
            try playback.start()
        } catch {
            tap.stop()
            throw AudioStackError.engineStartFailed(underlying: error)
        }
        return SessionEngine(tap: tap, ring: ring, engine: playback)
    }

    /// Stop capture + playback for one session and release its resources.
    private func tearDownSession(_ id: AudioObjectID) {
        guard let sess = engines.removeValue(forKey: id) else { return }
        sess.engine.stop()
        sess.tap.stop()
    }

    private func surface(_ error: Error, context: String) {
        let stackError: AudioStackError
        if let e = error as? AudioStackError { stackError = e }
        else { stackError = .engineStartFailed(underlying: error) }
        lastError = stackError
        log.error("[\(context, privacy: .public)] \(String(describing: stackError), privacy: .public)")
    }

    private static func validateTapFormat(_ asbd: AudioStreamBasicDescription) throws {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsOK = asbd.mBitsPerChannel == 32
        let channels = Int(asbd.mChannelsPerFrame)
        guard isFloat, bitsOK, asbd.mSampleRate > 0,
              channels >= 1, channels <= 2 else {
            throw AudioStackError.invalidTapFormat
        }
    }

    private static func makeInterleavedFloat32Format(sampleRate: Double,
                                                     channels: AVAudioChannelCount) -> AVAudioFormat {
        let ch = max(1, channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * ch, mChannelsPerFrame: ch,
            mBitsPerChannel: 32, mReserved: 0)
        if let format = AVAudioFormat(streamDescription: &asbd) { return format }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: ch)!
    }
}
