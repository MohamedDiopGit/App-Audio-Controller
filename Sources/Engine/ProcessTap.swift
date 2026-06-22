//
//  ProcessTap.swift
//  AppAudioController — Engine layer (capture side)
//
//  Owns the CAPTURE half for exactly one tapped process. This object is the
//  Core Audio side of the locked architectural split described in the build
//  spec: the capture half and the playback half are TWO SEPARATE Core Audio
//  clients connected ONLY by a lock-free `AudioRingBuffer`. ProcessTap is the
//  SOLE PRODUCER into that ring buffer; `TapProcessingEngine` is the sole
//  consumer. The two run on independent device clocks and never share an
//  AVAudioEngine (a single engine is backed by one Core Audio I/O unit / one
//  AudioDeviceID, so input-device != output-device is impossible inside one
//  engine — hence this out-of-engine capture path).
//
//  Lifecycle this file implements, in order:
//    1. Build a stereo-mixdown CATapDescription over the PROCESS-OBJECT id.
//    2. AudioHardwareCreateProcessTap  -> tap AudioObjectID.
//    3. Read kAudioTapPropertyFormat   -> the tap's AudioStreamBasicDescription.
//    4. AudioHardwareCreateAggregateDevice (PRIVATE, tap-list references the
//       tap *UUID string*, main sub-device = chosen output device UID).
//    5. AudioDeviceCreateIOProcIDWithBlock on the AGGREGATE id; the IO block
//       forwards inInputData straight into the ring buffer (RT-safe).
//    6. AudioDeviceStart / AudioDeviceStop.
//    7. Teardown in strict reverse order:
//       Stop -> DestroyIOProcID -> DestroyAggregateDevice -> DestroyProcessTap.
//

import Foundation
import CoreAudio
import AudioToolbox   // AudioDeviceCreateIOProcIDWithBlock / Start / Stop / DestroyIOProcID
import AVFAudio       // (not strictly needed here, but keeps the module's audio imports uniform)

/// Owns the capture pipeline (tap + private aggregate device + IOProc) for one process,
/// pumping captured frames into a caller-supplied `AudioRingBuffer`.
///
/// macOS 14.4 floor: the tap symbols link from 14.2 but Apple documents/supports 14.4,
/// so we gate the whole type with `@available(macOS 14.4, *)` per the spec.
@available(macOS 14.4, *)
final class ProcessTap {

    // MARK: - Public surface (must match the build spec exactly)

    /// The tap's stream format, read from `kAudioTapPropertyFormat` right after the tap is
    /// created. This is the single source of truth for the ring-buffer layout and for the
    /// playback engine's `AVAudioFormat` — every downstream format must equal this.
    private(set) var streamFormat: AudioStreamBasicDescription

    // MARK: - Stored configuration

    /// PROCESS-OBJECT AudioObjectID (class `kAudioProcessClassID`), NOT a pid. The #1 bug in
    /// this API is passing a pid here; `AudioProcessInfo.id` is already the translated object id.
    private let processObjectID: AudioObjectID

    /// Stable UID of the chosen hardware output device. Used both as the aggregate's main
    /// sub-device ("master") and as the single entry in its sub-device list.
    private let outputDeviceUID: String

    /// Human-readable, used for the tap + aggregate names (purely cosmetic / for Audio MIDI Setup
    /// debugging, though the aggregate is private so it won't show there).
    private let tapName: String

    // MARK: - Core Audio handles (owned; torn down in deinit)

    /// The CATapDescription is retained for the object's lifetime so its `uuid` (used as the
    /// aggregate's `kAudioSubTapUIDKey`) stays valid and so the description isn't deallocated
    /// out from under the HAL.
    private let tapDescription: CATapDescription

    /// AudioObjectID of the tap returned by `AudioHardwareCreateProcessTap`. `kAudioObjectUnknown`
    /// (0) means "not created". Destroyed BY VALUE via `AudioHardwareDestroyProcessTap`.
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// AudioObjectID of the private aggregate device hosting the tap. The IOProc is installed on
    /// THIS id (not the tap id), and the tap's audio arrives as this device's INPUT stream.
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// The IOProc handle. Optional because `AudioDeviceCreateIOProcIDWithBlock` hands back an
    /// `AudioDeviceIOProcID?` out-param; nil means "not installed".
    private var ioProcID: AudioDeviceIOProcID?

    /// Serial queue the HAL may dispatch the IO block on. Passing a queue (rather than nil) keeps
    /// the IO block off the HAL's internal RT thread's hot path is NOT what happens — the block
    /// still runs on a realtime thread serviced by this queue. We keep one dedicated queue so the
    /// block has a stable, high-priority context and so its lifetime is tied to this object.
    private let ioQueue = DispatchQueue(label: "com.appaudiocontroller.processtap.io",
                                        qos: .userInitiated)

    /// Tracks whether `AudioDeviceStart` succeeded, so `stop()`/`deinit` only stop a running device
    /// and we never double-stop.
    private var isStarted = false

    // MARK: - Init

    /// Builds the tap and the private aggregate device. Reads the tap's stream
    /// format into `streamFormat`. Does NOT install the IOProc — that happens in
    /// `start(writingTo:)`, once the caller has built a ring buffer sized for this
    /// tap's *actual* format (channel count + sample rate).
    ///
    /// - Parameters:
    ///   - process: The process to tap. `process.id` MUST be the process-object AudioObjectID.
    ///   - outputDeviceUID: Stable UID of the chosen output device (the aggregate's clock master).
    ///   - muteWhileTapped: If true, the tapped app is muted from hardware while we read it
    ///     (`.mutedWhenTapped`); otherwise it stays audible (`.unmuted`).
    /// - Throws: `AudioStackError.osStatus` for any failing Core Audio call, or
    ///   `AudioStackError.invalidTapFormat` if the tap reports a zero/garbage format.
    init(process: AudioProcessInfo,
         outputDeviceUID: String,
         muteWhileTapped: Bool) throws {

        self.processObjectID = process.id
        self.outputDeviceUID = outputDeviceUID
        self.tapName = "AppAudioController-Tap-\(process.pid)"

        // ---------------------------------------------------------------------
        // 1) Describe the tap: a STEREO MIXDOWN of the given PROCESS OBJECT(S).
        //    The array is [AudioObjectID] of process objects — never pids. We pass
        //    the single chosen process; the tap mixes its output to 2 channels.
        // ---------------------------------------------------------------------
        let desc = CATapDescription(stereoMixdownOfProcesses: [process.id])

        // Assign an explicit UUID. This exact UUID *string* is what the aggregate's tap-list
        // references via `kAudioSubTapUIDKey` — NOT the tap's AudioObjectID. Setting it here
        // (rather than reading whatever default it had) guarantees the two agree.
        desc.uuid = UUID()

        // Cosmetic name (the aggregate is private so it won't appear in Audio MIDI Setup).
        desc.name = tapName

        // Private to this process: REQUIRED to pair with the private aggregate + tap-auto-start
        // composition below; otherwise the tap would be visible to / shared with other clients.
        // Note: the underlying ObjC property is literally named `private`; Swift imports it as
        // `isPrivate`.
        desc.isPrivate = true

        // Whether the tapped app keeps reaching the speakers while we capture it.
        // `.mutedWhenTapped` (rawValue 2) mutes it from hardware only while a client is actively
        // reading; `.unmuted` (0) leaves it audible.
        desc.muteBehavior = muteWhileTapped ? .mutedWhenTapped : .unmuted

        self.tapDescription = desc

        // ---------------------------------------------------------------------
        // 2) Create the tap. The out-param is UnsafeMutablePointer<AudioObjectID>!;
        //    on success it receives the tap's AudioObjectID. We seed it to
        //    kAudioObjectUnknown so a noErr-but-unset result is still caught.
        // ---------------------------------------------------------------------
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try AudioStackError.check(
            AudioHardwareCreateProcessTap(desc, &createdTapID),
            "AudioHardwareCreateProcessTap"
        )
        guard createdTapID != AudioObjectID(kAudioObjectUnknown) else {
            // noErr with an unknown id is the documented failure shape for several HAL calls;
            // surface it as an OSStatus error rather than silently proceeding with id 0.
            throw AudioStackError.osStatus(kAudioHardwareBadObjectError,
                                           context: "AudioHardwareCreateProcessTap returned kAudioObjectUnknown")
        }
        self.tapID = createdTapID

        // ---------------------------------------------------------------------
        // 3) Read the tap's stream format from kAudioTapPropertyFormat, on the
        //    TAP object id (NOT the aggregate), global scope / main element — the
        //    tap class only has the global scope and a single main element.
        //    `streamFormat` must be assigned before any `throw` that escapes init
        //    so the property is always initialized; we read it via a local helper.
        // ---------------------------------------------------------------------
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(
            createdTapID,
            &formatAddress,
            0, nil,            // no qualifier
            &asbdSize, &asbd
        )

        // We've already created the tap, so on ANY failure here we must destroy it before
        // throwing — otherwise we'd leak a tap (and potentially leave the app muted if
        // muteBehavior != .unmuted). deinit won't run for a failed init, so clean up manually.
        guard formatStatus == noErr else {
            AudioHardwareDestroyProcessTap(createdTapID)
            self.streamFormat = AudioStreamBasicDescription()
            throw AudioStackError.osStatus(formatStatus, context: "AudioObjectGetPropertyData(kAudioTapPropertyFormat)")
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            AudioHardwareDestroyProcessTap(createdTapID)
            self.streamFormat = asbd
            throw AudioStackError.invalidTapFormat
        }
        self.streamFormat = asbd

        // ---------------------------------------------------------------------
        // 4) Build the PRIVATE aggregate device that actually carries the tap's
        //    audio. The dictionary keys are the documented aggregate composition
        //    keys; their literal CFString values matter, so we use the SDK
        //    constants (kAudioAggregateDevice*Key / kAudioSubTap*Key /
        //    kAudioSubDeviceUIDKey) rather than raw strings.
        //
        //    CRITICAL detail: the tap-list entry references the tap by its UUID
        //    *string* (desc.uuid.uuidString), NOT by `tapID`. Mixing these up
        //    yields an empty/invalid aggregate that produces silence.
        // ---------------------------------------------------------------------
        let aggregateUID = UUID().uuidString   // the aggregate's OWN uid (distinct from the tap's)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: tapName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // Clock master = the chosen output device, by UID string.
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            // REQUIRED true to use the tap list + auto-start composition; keeps it private to us.
            kAudioAggregateDeviceIsPrivateKey: true,
            // Not a stacked (multi-output) aggregate.
            kAudioAggregateDeviceIsStackedKey: false,
            // With auto-start true, AudioDeviceStart defers IO until the tapped process actually
            // produces audio — so initial silence is expected, not an error.
            kAudioAggregateDeviceTapAutoStartKey: true,
            // One real sub-device: the chosen output, referenced by its UID.
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            // The tap list: one sub-tap, drift-compensated, referenced by the tap UUID STRING.
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString
                ]
            ]
        ]

        var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdAggregateID)
        guard aggStatus == noErr, createdAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            // Aggregate failed — destroy the already-created tap before throwing (no deinit on
            // failed init).
            AudioHardwareDestroyProcessTap(createdTapID)
            throw AudioStackError.osStatus(aggStatus, context: "AudioHardwareCreateAggregateDevice")
        }
        self.aggregateID = createdAggregateID

        // The tap + private aggregate are created and the format is known. The
        // IOProc is NOT installed here — `start(writingTo:)` installs it once the
        // caller has a ring buffer sized for `streamFormat`. The device is not
        // started yet.
    }

    // MARK: - Start / Stop

    /// Installs the capture IOProc (writing into `ringBuffer`) if not already
    /// installed, then begins the IO cycle on the aggregate device.
    ///
    /// The ring buffer is supplied HERE rather than at `init` so the caller can
    /// build it from the tap's real `streamFormat` (channel count + sample rate),
    /// which is only known after `init` has read `kAudioTapPropertyFormat`.
    ///
    /// With tap-auto-start enabled, the HAL defers real IO until the tapped
    /// process produces audio, so returning successfully does not guarantee
    /// immediate samples — initial silence is normal.
    ///
    /// - Parameter ringBuffer: the SPSC ring buffer this tap produces into; the
    ///   SAME instance the playback engine drains.
    func start(writingTo ringBuffer: AudioRingBuffer) throws {
        guard !isStarted else { return }
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioStackError.osStatus(kAudioHardwareBadObjectError,
                                           context: "ProcessTap.start with no aggregate")
        }

        // Install the IOProc once. The AudioDeviceIOBlock runs on a Core Audio
        // REALTIME thread and returns Void. Inside it we do EXACTLY ONE thing:
        // forward the captured input buffer list into the ring buffer. No locks,
        // no allocation, no ARC churn, no logging.
        //
        // We capture `ring` (a class ref) and `bpf` (a value) ONCE at block
        // creation — there is no per-callback ARC traffic. The ring buffer is
        // owned by the orchestrator for at least as long as this proc lives (the
        // proc is destroyed before the ring is released), so the reference is
        // always valid while the block can run.
        if ioProcID == nil {
            let ring = ringBuffer
            // Bytes per frame as the tap reports it. For NON-interleaved Float32
            // this is the size of ONE channel's sample (4); for interleaved it is
            // channels * 4. Either way `firstBuffer.mDataByteSize / bpf` yields the
            // frame count, because the first buffer holds exactly `frames` frames'
            // worth of bytes in both layouts. The ring's write() then interleaves
            // whatever layout the buffer list actually carries.
            let bpf = streamFormat.mBytesPerFrame
            var createdProcID: AudioDeviceIOProcID?
            let ioBlock: AudioDeviceIOBlock = { _ /*inNow*/,
                                                inInputData /*const AudioBufferList* — the tapped audio*/,
                                                _ /*inInputTime*/,
                                                _ /*outOutputData — unused: capture only*/,
                                                _ /*inOutputTime*/ in
                guard bpf > 0 else { return }
                let firstBuffer = inInputData.pointee.mBuffers
                let frames = AVAudioFrameCount(firstBuffer.mDataByteSize / bpf)
                guard frames > 0 else { return }
                // SOLE producer write. Return value (false on overrun) is ignored
                // on the RT thread — dropping under overrun is correct; never block.
                _ = ring.write(inInputData, frames: frames)
            }

            let procStatus = AudioDeviceCreateIOProcIDWithBlock(
                &createdProcID,
                aggregateID,
                ioQueue,
                ioBlock
            )
            guard procStatus == noErr, let procID = createdProcID else {
                throw AudioStackError.osStatus(procStatus, context: "AudioDeviceCreateIOProcIDWithBlock")
            }
            self.ioProcID = procID
        }

        guard let procID = ioProcID else {
            throw AudioStackError.osStatus(kAudioHardwareBadObjectError,
                                           context: "ProcessTap.start with no IOProc")
        }
        try AudioStackError.check(
            AudioDeviceStart(aggregateID, procID),
            "AudioDeviceStart(aggregate)"
        )
        isStarted = true
    }

    /// Stops the IO cycle. Safe to call when not started (no-op). Does NOT destroy the proc/
    /// aggregate/tap — full teardown happens in `deinit` in the correct order.
    func stop() {
        guard isStarted, let procID = ioProcID,
              aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        // Ignore the status: stopping a device that the HAL has already quiesced can return a
        // benign error, and there's nothing useful to do with a failure during shutdown.
        _ = AudioDeviceStop(aggregateID, procID)
        isStarted = false
    }

    // MARK: - Teardown

    deinit {
        // Strict reverse-of-creation order, per the HAL contract:
        //   AudioDeviceStop -> AudioDeviceDestroyIOProcID -> AudioHardwareDestroyAggregateDevice
        //   -> AudioHardwareDestroyProcessTap (tap id BY VALUE).
        // Doing this out of order (e.g. destroying the aggregate while the proc is live, or
        // destroying the tap before the aggregate that references it) leaks objects or wedges
        // the HAL, and can leave the tapped app muted if muteBehavior wasn't .unmuted.

        if aggregateID != AudioObjectID(kAudioObjectUnknown), let procID = ioProcID {
            if isStarted {
                _ = AudioDeviceStop(aggregateID, procID)
                isStarted = false
            }
            // Destroy the IOProc created with AudioDeviceCreateIOProcIDWithBlock. This releases
            // the HAL's hold on the IO block (and thus its captured ring-buffer reference).
            _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            // Aggregate destruction is asynchronous — it may complete after this returns. That's
            // fine: we no longer reference it, and the tap below is independent of that async work.
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            // BY VALUE (not a pointer). This is the call that un-mutes the tapped app if we had
            // muted it; leaking it can leave audio muted system-wide for that process.
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
