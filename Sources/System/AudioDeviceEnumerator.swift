// System/AudioDeviceEnumerator.swift
//
// Enumerates hardware OUTPUT-capable audio devices and exposes the system
// default output device. Produces the shared `AudioOutputDevice` model used
// throughout the audio stack (selection persistence, aggregate-device main
// sub-device key, output-node binding).
//
// ARCHITECTURAL ROLE
// ------------------
// This is a pure System-layer utility. It does NOT touch AVAudioEngine, taps,
// or aggregate devices. It only reads HAL device properties so higher layers
// (AudioTapManager) can:
//   * present a device picker (id + name) to the UI,
//   * persist a stable `uid` and resolve it back to a live numeric id later
//     (device ids are NOT stable across reboots / replug — only the UID is),
//   * obtain the chosen output device's UID for the private aggregate's
//     `kAudioAggregateDeviceMainSubDeviceKey` and sub-device list,
//   * obtain the chosen output device's numeric id for
//     `kAudioOutputUnitProperty_CurrentDevice` on the playback engine's
//     output node,
//   * fall back to the system default output device when nothing is selected.
//
// THREADING / OS
// --------------
// No `@available` gate is required here: kAudioHardwarePropertyDevices and the
// per-device selectors used below predate macOS 14 (they are macOS 10.x APIs).
// Only the *tap* APIs need the 14.4 gate, and none of those are touched here.
// These reads are cheap, synchronous, and safe to call from the main actor
// during UI refresh.
//
// CORE AUDIO C-INTEROP POLICY
// ---------------------------
// Per the build spec, ALL AudioObjectGetPropertyData / ...DataSize calls are
// funneled through Support/CoreAudioHelpers.swift (the `CoreAudio` enum). The
// ONE exception is the stream-configuration read: it returns a variable-length
// AudioBufferList that cannot be expressed as a fixed scalar/array<T> through
// the generic helpers, so it is sized + read + iterated locally here using
// UnsafeMutableAudioBufferListPointer. That local read still uses only the
// public AudioObjectGetPropertyDataSize / AudioObjectGetPropertyData entry
// points (it is the documented exception, not a second ad-hoc property layer).

import CoreAudio
import Foundation

enum AudioDeviceEnumerator {

    // MARK: - Public API

    /// All hardware devices that have at least one OUTPUT channel.
    ///
    /// Devices with zero output channels (pure input devices like a USB mic, or
    /// an aggregate exposing only input streams) are filtered out. Devices that
    /// fail to yield a UID are also dropped, because the UID is mandatory for
    /// persistence and for keying the aggregate device's main sub-device — a
    /// device we can't reference downstream is useless to us.
    static func outputDevices() -> [AudioOutputDevice] {
        let deviceIDs = allDeviceIDs()

        var devices: [AudioOutputDevice] = []
        devices.reserveCapacity(deviceIDs.count)

        for deviceID in deviceIDs where deviceID != AudioObjectID(kAudioObjectUnknown) {
            // Output-capability gate: only keep devices with output channels.
            guard outputChannelCount(of: deviceID) > 0 else { continue }

            // UID is required (persistence key + aggregate main sub-device key).
            // Without it the device is unusable downstream, so skip it.
            guard let uid = uid(for: deviceID) else { continue }

            // Name is best-effort: fall back to the UID so the picker never
            // shows a blank row.
            let name = self.name(for: deviceID) ?? uid

            devices.append(AudioOutputDevice(id: deviceID, uid: uid, name: name))
        }

        return devices
    }

    /// Resolves a persisted UID string back to a live `AudioOutputDevice`.
    ///
    /// Numeric AudioDeviceIDs are reassigned across reboots and device
    /// reconnects, so the persisted selection is stored as a UID and re-resolved
    /// at runtime. We resolve by scanning the current output-device list and
    /// matching on UID rather than via kAudioHardwarePropertyDeviceForUID +
    /// AudioValueTranslation: the scan reuses the exact same output-capability
    /// filtering as `outputDevices()`, so a UID that no longer maps to an
    /// output-capable device correctly returns nil (and AudioValueTranslation
    /// has historically been awkward/error-prone to bridge from Swift).
    static func device(forUID uid: String) -> AudioOutputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    /// The current system default output device, mapped to `AudioOutputDevice`.
    ///
    /// Used by AudioTapManager as the fallback main sub-device / output binding
    /// when the user hasn't explicitly chosen a device. Note this reads the
    /// *system* default (kAudioHardwarePropertyDefaultOutputDevice); it does NOT
    /// change it.
    static func defaultOutputDevice() -> AudioOutputDevice? {
        // Read the default-output AudioDeviceID off the system object.
        var address = CoreAudio.address(
            kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        guard let deviceID = CoreAudio.readScalar(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            default: AudioObjectID(kAudioObjectUnknown)
        ), deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        // Build the full model from the resolved id. We do NOT require the
        // default device to pass the output-channel filter (it is the default
        // *output* by definition), but we DO require a UID for downstream use.
        guard let uid = uid(for: deviceID) else { return nil }
        let name = self.name(for: deviceID) ?? uid
        return AudioOutputDevice(id: deviceID, uid: uid, name: name)
    }

    /// Reads the stable UID for a given numeric device id, or nil if absent.
    ///
    /// Exposed publicly because callers sometimes hold a numeric id (e.g. the
    /// one returned by kAudioHardwarePropertyDefaultOutputDevice or one chosen
    /// in the UI) and need its UID for the aggregate description.
    static func uid(for deviceID: AudioObjectID) -> String? {
        // kAudioDevicePropertyDeviceUID ('uid '): a stable CFString persistent
        // across reboots/reconnects. Global scope / main element. CoreAudio's
        // readCFString does the +1 ARC bridging and treats empty as nil.
        var address = CoreAudio.address(
            kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return CoreAudio.readCFString(deviceID, &address)
    }

    // MARK: - Private helpers

    /// The full list of HAL device ids (input, output, aggregate — everything).
    ///
    /// kAudioHardwarePropertyDevices ('dev#') on the system object returns an
    /// array of AudioDeviceID. Routed through the CoreAudio helper, which does
    /// the GetPropertyDataSize -> allocate -> GetPropertyData two-step and sizes
    /// the array as dataSize / MemoryLayout<AudioObjectID>.size. On any failure
    /// we return an empty list so the picker degrades gracefully rather than
    /// throwing into the UI.
    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = CoreAudio.address(
            kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return (try? CoreAudio.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            type: AudioObjectID.self
        )) ?? []
    }

    /// Best-effort human-readable device name.
    ///
    /// Uses kAudioObjectPropertyName ('lnam') — the MODERN, non-deprecated
    /// selector — NOT kAudioDevicePropertyDeviceNameCFString (which now lives in
    /// AudioHardwareDeprecated.h as a literal alias of the same 'lnam' value).
    /// Global scope / main element. Returns nil if the name can't be read or is
    /// empty; the caller falls back to the UID.
    private static func name(for deviceID: AudioObjectID) -> String? {
        var address = CoreAudio.address(
            kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return CoreAudio.readCFString(deviceID, &address)
    }

    /// Counts a device's OUTPUT channels via its output-scope stream config.
    ///
    /// This is the local exception to "all reads go through CoreAudioHelpers":
    /// kAudioDevicePropertyStreamConfiguration ('slay') returns a VARIABLE-LENGTH
    /// AudioBufferList (one AudioBuffer per stream; the C struct only declares a
    /// single trailing element), which can't be modeled as a fixed scalar<T> or
    /// array<T>. We therefore size it with AudioObjectGetPropertyDataSize,
    /// allocate raw memory of exactly that size, read into it, then iterate the
    /// buffers safely with UnsafeMutableAudioBufferListPointer and sum
    /// mNumberChannels. A total > 0 means the device can play audio.
    ///
    /// CRITICAL: the scope MUST be kAudioObjectPropertyScopeOutput ('outp').
    /// Querying global or input scope would misclassify devices — an aggregate
    /// or combo device can have both input and output streams, and only the
    /// output-scope config tells us whether it can RECEIVE playback.
    private static func outputChannelCount(of deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // 1) Ask how many bytes the buffer-list payload needs.
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return 0 }

        // 2) Allocate raw memory with AudioBufferList alignment. We deliberately
        //    use raw allocation (not a fixed AudioBufferList value) because the
        //    real payload is longer than the one-element struct for multi-stream
        //    devices; under-allocating would read out of bounds.
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        // `defer` guarantees the allocation is freed on every exit path — no leak
        // even on the early-return error branch below.
        defer { rawBuffer.deallocate() }

        // 3) Read the actual stream configuration into our buffer.
        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer)
        guard dataStatus == noErr else { return 0 }

        // 4) Iterate the variable-length buffer list. UnsafeMutableAudioBufferListPointer
        //    correctly walks `mNumberBuffers` entries past the single declared
        //    `mBuffers` element, so we never assume a fixed buffer count.
        let bufferListPointer = UnsafeMutableAudioBufferListPointer(
            rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        )

        var channels = 0
        for buffer in bufferListPointer {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }
}
