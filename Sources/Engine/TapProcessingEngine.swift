// Engine/TapProcessingEngine.swift
//
// The PLAYBACK half of the per-app audio pipeline.
//
// ARCHITECTURE (locked, see BUILD SPEC):
// This is a STANDALONE AVAudioEngine that has NOTHING to do with the capture side.
// The capture side (ProcessTap + private aggregate device IOProc) lives entirely
// outside AVAudioEngine and writes frames into an AudioRingBuffer. This engine
// DRAINS that same ring buffer:
//
//     AVAudioSourceNode (renderBlock pulls ring buffer, RT-safe)
//         -> AVAudioUnitEQ (10-band parametric "graphic" EQ)
//         -> engine.mainMixerNode (per-app volume via outputVolume)
//         -> engine.outputNode (bound to the CHOSEN output AudioDeviceID)
//
// WHY a SEPARATE engine (not one engine doing input->output): one AVAudioEngine's
// inputNode and outputNode are backed by ONE Core Audio I/O unit (one AUHAL, one
// AudioDeviceID). Setting kAudioOutputUnitProperty_CurrentDevice changes BOTH the
// input AND the output device, so you cannot capture from app X while playing to a
// user-chosen device Y inside a single engine. Hence capture is done outside the
// engine (the tap) and this engine only plays back. The two run on independent
// device clocks; the AudioRingBuffer decouples them.

import AVFAudio
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// The playback side of the pipeline. Owns one AVAudioEngine whose source node
/// drains the shared `AudioRingBuffer`, runs the signal through a 10-band
/// parametric EQ and the main mixer (per-app volume), and emits to a chosen
/// hardware output device bound via the low-level AUHAL device property.
///
/// Threading: all public methods are intended to be called from the main thread
/// (the orchestrating `AudioTapManager` is @MainActor). The render block runs on
/// AVAudioEngine's realtime render thread and is strictly RT-safe. Live control
/// mutations (`setBandGain`, `setVolume`) write to reference-type EQ band objects
/// and `mixer.outputVolume`, which are safe to set live and take effect on the
/// next render cycle.
final class TapProcessingEngine {

    // MARK: - Standard 10-band graphic-EQ center frequencies

    /// ISO octave-spaced center frequencies (Hz) for the 10-band graphic EQ.
    /// The UI iterates over these to build its 10 gain sliders, and `init`
    /// assigns one to each EQ band. The top band (16 kHz) is clamped below the
    /// capture Nyquist at runtime so it stays in the valid 20 Hz..Nyquist range
    /// for low-sample-rate taps.
    static let bandCenterFrequencies: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    // MARK: - Stored properties

    private let engine = AVAudioEngine()

    /// The 10-band parametric EQ. Reference type; its `bands` elements are mutated
    /// live by `setBandGain`.
    private let eq = AVAudioUnitEQ(numberOfBands: TapProcessingEngine.bandCenterFrequencies.count)

    /// Source node whose render block drains the ring buffer on the RT thread.
    /// Declared as an implicitly-unwrapped optional only because the render block
    /// must capture `self`-owned state (the ring buffer); we assign it in `init`
    /// after the captured values exist.
    private var sourceNode: AVAudioSourceNode!

    /// The shared SPSC ring buffer. The ProcessTap (capture) is the SOLE producer;
    /// this engine's render block is the SOLE consumer. Captured by the render
    /// block — see RT-safety notes on `init`.
    private let ringBuffer: AudioRingBuffer

    /// The engine's processing format: AVAudioEngine's STANDARD (non-interleaved)
    /// Float32 with the same channel count + sample rate as the tap. Source node,
    /// EQ, and mixer connections all use this EXACT format so there is no implicit
    /// conversion inside the graph, until the final mainMixer -> outputNode hop,
    /// where the output device may resample if it runs at a different rate. The
    /// ring buffer de-interleaves into this format's planar render buffers.
    private let tapFormat: AVAudioFormat

    /// The currently bound output device. Tracked so we can no-op redundant
    /// rebinds and so `setOutputDevice` knows whether a restart is needed.
    private var currentOutputDeviceID: AudioObjectID

    // MARK: - Init

    /// - Parameters:
    ///   - tapFormat: the tap's stream format (from `kAudioTapPropertyFormat`).
    ///     Used verbatim to build the AVAudioFormat the whole graph runs at.
    ///   - outputDeviceID: numeric AudioDeviceID of the chosen hardware output
    ///     device. Bound to the outputNode's underlying AUHAL BEFORE prepare().
    ///   - ringBuffer: the SAME instance the ProcessTap writes into.
    init(tapFormat asbd: AudioStreamBasicDescription,
         outputDeviceID: AudioObjectID,
         ringBuffer: AudioRingBuffer) throws {

        self.ringBuffer = ringBuffer
        self.currentOutputDeviceID = outputDeviceID

        // ---- 1. Build the engine's processing format ------------------------
        //
        // We do NOT reuse the tap's ASBD verbatim. Process taps frequently report
        // a NON-interleaved Float32 ASBD, and AVAudioEngine's nodes (source node,
        // EQ, mixer) want the engine's STANDARD format — deinterleaved Float32.
        // We therefore build a standard format with the SAME channel count and
        // sample rate as the tap and run the whole graph at it. The shared
        // AudioRingBuffer de-interleaves its interleaved store into this format's
        // planar buffers on read, so the producer's layout (whatever it is) and
        // this consumer format never have to match directly.
        //
        // standardFormatWithSampleRate(_:channels:) is failable (nil for an
        // unsupported channel count / rate); the tap is mono/stereo so 1–2
        // channels always succeed, but we guard and surface invalidTapFormat
        // rather than force-unwrap.
        let sampleRate = asbd.mSampleRate
        let channels = max(1, AVAudioChannelCount(asbd.mChannelsPerFrame))
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: channels) else {
            throw AudioStackError.invalidTapFormat
        }
        self.tapFormat = format

        // ---- 2. Configure the 10-band parametric EQ ------------------------
        //
        // CRITICAL: every AVAudioUnitEQ band defaults to bypass = true. If we
        // don't clear bypass, the EQ silently passes audio through flat and the
        // gain sliders do nothing — a classic "EQ has no effect" bug. We set
        // each band to .parametric, assign its center frequency (clamped below
        // Nyquist), a 1-octave bandwidth (bandwidth is in OCTAVES, not Hz),
        // 0 dB gain (the UI drives this live), and bypass = false.
        eq.globalGain = 0
        let nyquist = Float(tapFormat.sampleRate / 2.0)
        let centers = TapProcessingEngine.bandCenterFrequencies
        for (index, band) in eq.bands.enumerated() {
            // Defensive: if numberOfBands and the constant ever diverge, only
            // configure the bands we have frequencies for; leave any extras
            // bypassed. (They are constructed identical, so this never triggers
            // in practice.)
            guard index < centers.count else {
                band.bypass = true
                continue
            }
            band.filterType = .parametric
            // Clamp frequency strictly below Nyquist. Subtract 1 Hz so we never
            // sit exactly on Nyquist (an invalid edge for the filter). Also keep
            // the documented >= 20 Hz lower bound.
            let desired = centers[index]
            let clamped = min(desired, nyquist - 1.0)
            band.frequency = max(20.0, clamped)
            band.bandwidth = 1.0     // octaves
            band.gain = 0.0          // dB; live control surface
            band.bypass = false      // MUST clear — bands default to bypassed
        }

        // ---- 3. Build the RT-safe source node ------------------------------
        //
        // The render block runs on AVAudioEngine's realtime render thread. It is
        // the SOLE consumer of the ring buffer. RT-SAFETY RULES (all observed
        // below): NO locks, NO malloc/free, NO ARC retain/release traffic, NO
        // Foundation calls, NO logging. We capture `ringBuffer` (a stable class
        // reference) into a local `unowned`-style closure capture so the block
        // does not retain/release on every render cycle.
        //
        // We capture the ring buffer by an unmanaged-style local constant. Using
        // `[ringBuffer]` would still be an owned capture but it is captured ONCE
        // at closure creation, not per call, so there is no per-render ARC
        // traffic — the closure simply holds the reference for its lifetime. That
        // is RT-safe. (We deliberately do NOT capture `self`.)
        let ring = ringBuffer
        self.sourceNode = AVAudioSourceNode(format: tapFormat) {
            (isSilence: UnsafeMutablePointer<ObjCBool>,
             _ timestamp: UnsafePointer<AudioTimeStamp>,
             frameCount: AVAudioFrameCount,
             outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus in

            // Drain `frameCount` frames from the ring buffer directly into the
            // engine-provided output AudioBufferList. The ring buffer honors each
            // AudioBuffer.mDataByteSize internally and performs no allocation.
            //
            // On underrun (producer hasn't filled enough yet — expected at start
            // because the aggregate uses TapAutoStart and waits for the tapped
            // process to make sound) we set isSilence = true and return noErr.
            // The engine then treats the buffers as silence, avoiding clicks. We
            // do NOT log or throw here — that would violate RT-safety.
            if ring.read(into: outputData, frames: frameCount) {
                isSilence.pointee = false
                return noErr
            } else {
                isSilence.pointee = true
                return noErr
            }
        }

        // ---- 4. Wire the graph with EXPLICIT formats -----------------------
        //
        // Attaching before connecting is required. We connect source -> eq -> the
        // (lazily created) mainMixerNode all at the tap format so there is no
        // hidden conversion in the EQ path. Referencing engine.mainMixerNode
        // instantiates it and auto-connects mainMixer -> outputNode. If the
        // chosen output device runs at a different sample rate, that final
        // mainMixer -> outputNode connection performs the sample-rate conversion;
        // we deliberately keep the source + EQ at the capture rate.
        engine.attach(sourceNode)
        engine.attach(eq)
        engine.connect(sourceNode, to: eq, format: tapFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: tapFormat)

        // ---- 5. Per-app volume default -------------------------------------
        // outputVolume is linear 0.0 (silent) ... 1.0 (unity). Default to unity.
        engine.mainMixerNode.outputVolume = 1.0

        // ---- 6. Bind the output device to a specific AudioDeviceID ----------
        //
        // There is NO AVFoundation-level API to choose the output device on the
        // outputNode of an already-built engine without the throwing
        // auAudioUnit.setDeviceID(_:) path. Per the spec we use the lower-level
        // AUHAL property kAudioOutputUnitProperty_CurrentDevice (== 2000) via
        // AudioUnitSetProperty on engine.outputNode.audioUnit (the RAW AudioUnit,
        // NOT .auAudioUnit). This MUST be set BEFORE prepare()/start().
        try bindOutputDevice(outputDeviceID)
    }

    // MARK: - Lifecycle

    /// Prepares and starts the engine. Call after the ProcessTap has started so
    /// the ring buffer is already filling (initial silence is still fine).
    func start() throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Wrap the underlying AVAudioEngine error in our typed error so the
            // orchestrator/UI can surface it uniformly.
            throw AudioStackError.engineStartFailed(underlying: error)
        }
    }

    /// Stops the engine. Idempotent — safe to call when not running.
    func stop() {
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Live control surface

    /// Sets a single EQ band's gain in dB. Safe to call live from the main
    /// thread; the band object is a reference type and the change is picked up on
    /// the next render cycle. Out-of-range indices are ignored. Gain is clamped
    /// to the documented -96...+24 dB range.
    func setBandGain(_ index: Int, dB: Float) {
        guard index >= 0, index < eq.bands.count else { return }
        eq.bands[index].gain = max(-96.0, min(24.0, dB))
    }

    /// Sets the per-app (master) volume. Linear 0.0...1.0, clamped.
    func setVolume(_ linear: Float) {
        // 0–1.0 → normal attenuation via outputVolume (no EQ gain).
        // 1.0–3.0 → outputVolume stays at 1.0; we use eq.globalGain for dB boost:
        //   1.0 = 0 dB, 2.0 = +10 dB (~3×), 3.0 = +20 dB (10×).
        // AVAudioUnitEQ.globalGain is a real audio-unit parameter — it is NOT
        // clamped like outputVolume and gives genuine signal amplification.
        engine.mainMixerNode.outputVolume = max(0.0, min(1.0, linear))
        let boostDB: Float = linear > 1.0 ? min((linear - 1.0) * 10.0, 40.0) : 0
        eq.globalGain = boostDB
    }

    /// Re-binds the engine output to a different hardware device.
    ///
    /// The AUHAL output device property cannot be safely changed while the engine
    /// is running, so we stop -> rebind -> (re)prepare -> restart if we were
    /// running. We no-op if the device is unchanged. The node formats are NOT
    /// auto-renegotiated by AVAudioEngine after a device change, but since our
    /// graph runs at the fixed tap format (the mainMixer -> outputNode hop absorbs
    /// any rate difference of the new device) we simply prepare() again.
    func setOutputDevice(_ deviceID: AudioObjectID) throws {
        guard deviceID != currentOutputDeviceID else { return }

        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }

        try bindOutputDevice(deviceID)

        if wasRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw AudioStackError.engineStartFailed(underlying: error)
            }
        }
    }

    // MARK: - Private: AUHAL output device binding

    /// Sets kAudioOutputUnitProperty_CurrentDevice on the output node's RAW
    /// AudioUnit. This is the only way to point an AVAudioEngine's output at a
    /// specific device with the low-level API.
    ///
    /// WHY .audioUnit and not .auAudioUnit: `engine.outputNode.audioUnit` is the
    /// classic C `AudioUnit` (AudioComponentInstance) that AudioUnitSetProperty
    /// expects. `engine.outputNode.auAudioUnit` is the AUv3 `AUAudioUnit` object
    /// whose `deviceID` is READ-ONLY (the writable path there is the throwing
    /// `setDeviceID(_:)`). The spec mandates the low-level property, so we use the
    /// raw unit.
    private func bindOutputDevice(_ deviceID: AudioObjectID) throws {
        guard let outputAU = engine.outputNode.audioUnit else {
            // No underlying AudioUnit means we cannot bind the device. Surface a
            // typed error with a descriptive context. Using -1 (kAudio_UnimplementedError
            // family) as a stand-in OSStatus since there is no real OSStatus here.
            throw AudioStackError.osStatus(-1, context: "engine.outputNode.audioUnit was nil; cannot set output device")
        }

        // AudioUnitSetProperty copies the value out of the pointer synchronously,
        // so a local `var` is sufficient and there are no lifetime concerns. The
        // value is passed by reference (UnsafeRawPointer) with its exact byte
        // size. kAudioOutputUnitProperty_CurrentDevice lives on the GLOBAL scope,
        // element 0.
        var device = deviceID
        let status = withUnsafeMutablePointer(to: &device) { ptr -> OSStatus in
            AudioUnitSetProperty(
                outputAU,
                kAudioOutputUnitProperty_CurrentDevice,   // == 2000
                kAudioUnitScope_Global,
                0,                                         // element 0
                ptr,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        try AudioStackError.check(status, "AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice) -> \(deviceID)")

        currentOutputDeviceID = deviceID
    }

    // MARK: - Teardown

    deinit {
        // Ensure the engine is stopped so the RT render thread is torn down and
        // stops touching the ring buffer before the ring buffer is released.
        if engine.isRunning {
            engine.stop()
        }
    }
}