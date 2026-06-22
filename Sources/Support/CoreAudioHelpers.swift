//
//  CoreAudioHelpers.swift
//  per-app audio menu-bar app
//
//  Support/CoreAudioHelpers.swift
//
//  ============================================================================
//  PURPOSE
//  ============================================================================
//  This is the ONE and ONLY place in the codebase that calls the raw
//  AudioObject* property C functions:
//
//      AudioObjectGetPropertyDataSize(_:_:_:_:_:)
//      AudioObjectGetPropertyData(_:_:_:_:_:_:)
//      AudioObjectSetPropertyData(_:_:_:_:_:_:)
//
//  Every other module (AudioProcessEnumerator, AudioDeviceEnumerator,
//  ProcessTap, ...) funnels its property reads/writes through the `CoreAudio`
//  enum below so that the gnarly, leak-prone pointer/qualifier/CFString bridging
//  lives in exactly one audited spot.
//
//  WHY a custom enum named `CoreAudio` rather than free functions?
//  ---------------------------------------------------------------
//  The system framework `CoreAudio` is imported below, but Swift resolves a
//  *local* type named `CoreAudio` ahead of the module of the same name when you
//  write `CoreAudio.readScalar(...)`. The framework's symbols (AudioObjectID,
//  AudioObjectGetPropertyData, kAudioObjectPropertyScopeGlobal, ...) are still
//  reachable because they are top-level declarations, not members of a
//  `CoreAudio` namespace. This is the same pattern AudioCap uses and it keeps
//  call sites tidy (`CoreAudio.address(...)`). The build spec's public API names
//  this exact enum, so we honour it.
//
//  THREADING
//  ---------
//  These helpers allocate, may throw, and use ARC bridging (`as String?`). They
//  are therefore for SETUP / ENUMERATION paths ONLY — never call them on a
//  realtime audio thread (the IOProc or the AVAudioSourceNode render block).
//  The realtime ring-buffer read/write paths in AudioRingBuffer must remain
//  lock-free and allocation-free; they do not use this file.
//  ============================================================================

import CoreAudio
import Foundation

// MARK: - Four-Char-Code Debug Formatter

extension AudioObjectPropertySelector {
    /// Formats an OSType / four-char-code (e.g. kAudioTapPropertyFormat == 'tfmt')
    /// as its human-readable four-character string for logging.
    ///
    /// WHY: Core Audio selectors, classes and many error codes are `OSType`
    /// values — 32-bit big-endian packings of four ASCII characters. When a
    /// property read fails you almost always want to see `'tfmt'` in the log,
    /// not `1952805748`. This makes diagnostics legible.
    ///
    /// Non-printable bytes are rendered as `?` so the result is always a safe,
    /// fixed-width 4-char token (wrapped in single quotes like the headers).
    var fourCharCodeString: String {
        return fourCharCodeToString(self)
    }
}

/// Converts any `OSType` (UInt32) four-char-code into a `'abcd'` style string.
///
/// The bytes are extracted most-significant-first because Core Audio packs the
/// characters big-endian regardless of host endianness (the constants in the
/// headers are written as multi-character literals like `'glob'`).
func fourCharCodeToString(_ code: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    let chars = bytes.map { byte -> Character in
        // Printable ASCII range is 0x20...0x7E; anything else becomes '?'.
        (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
    }
    return "'" + String(chars) + "'"
}

// MARK: - CoreAudio Helper Namespace

/// Typed, reusable, leak-safe wrappers over the AudioObject* property C-API.
///
/// All Core Audio property access in the app goes through here. Reads come in
/// four flavours, matching the shapes Core Audio actually returns:
///   * `readScalar`    — a single fixed-size POD value (UInt32, pid_t, AudioObjectID, ...)
///   * `readArray`     — a variable-length C array of POD values (device lists, ...)
///   * `readCFString`  — a +1-retained CFString, bridged so ARC frees it
///   * `readASBD`      — an AudioStreamBasicDescription (its own helper for clarity)
///   * `readWithQualifier` — a scalar read where the OS needs *input* qualifier
///                            bytes (e.g. PID -> process-object translation)
enum CoreAudio {

    // MARK: Address Construction

    /// Builds an `AudioObjectPropertyAddress`, the (selector, scope, element)
    /// triple every AudioObject* call needs.
    ///
    /// Defaults match the overwhelmingly common case for the properties this
    /// app reads:
    ///   * scope  = kAudioObjectPropertyScopeGlobal ('glob') — hardware/process/tap
    ///              properties live in the global scope.
    ///   * element = kAudioObjectPropertyElementMain (== 0) — the modern spelling
    ///              of the deprecated kAudioObjectPropertyElementMaster.
    ///
    /// Callers that need a non-global scope (e.g. the output-scope stream
    /// configuration in AudioDeviceEnumerator uses kAudioObjectPropertyScopeOutput)
    /// pass it explicitly.
    ///
    /// NOTE: the returned value is a plain struct; AudioObject* takes it by
    /// `UnsafePointer`, so call sites pass it `inout` (`&address`). We expose it
    /// as a value and let callers hold a `var` because several reads reuse the
    /// same address.
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    // MARK: Scalar Read

    /// Reads a single fixed-size value of type `T` from `objectID`.
    ///
    /// Use for POD scalars whose size is known at compile time and equals the
    /// Core Audio payload size: UInt32 (the 0/1 "is running" flags),
    /// AudioObjectID (default-device translation), pid_t, etc.
    ///
    /// WHY a `default def: T` parameter and an Optional return rather than
    /// `throws`?  Many call sites (enumeration filters) want "give me the value
    /// or treat this object as not-applicable" semantics without a do/catch on
    /// every per-object read. We seed `outData` with `def` so that even on a
    /// short read the caller sees a defined value, and we return `nil` on any
    /// non-`noErr` status so the caller can `guard let`/`?? fallback`.
    ///
    /// POINTER SAFETY: `withUnsafeMutablePointer(to:)` hands Core Audio a stable
    /// address for `value` for the duration of the call only. `T` must be a
    /// trivial (no-ARC) type — passing a class/CFString here would be unsafe, so
    /// CFString has its own dedicated helper below.
    static func readScalar<T>(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress,
        default def: T
    ) -> T? {
        var value = def
        // `ioDataSize` is in/out: we tell Core Audio how many bytes we provide,
        // it tells us how many it wrote. For a fixed scalar these match.
        var dataSize = UInt32(MemoryLayout<T>.size)

        let status = withUnsafeMutablePointer(to: &value) { valuePtr -> OSStatus in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,            // inQualifierDataSize  — no qualifier for a plain scalar
                nil,          // inQualifierData
                &dataSize,    // ioDataSize (in: capacity, out: bytes written)
                valuePtr      // outData
            )
        }

        guard status == noErr else { return nil }
        return value
    }

    // MARK: Array Read (variable length)

    /// Reads a variable-length C array of POD values of type `T` (e.g. the
    /// system device list, the process-object list, per-process device lists).
    ///
    /// Two-step pattern, which is mandatory because the count is dynamic:
    ///   1. AudioObjectGetPropertyDataSize -> total byte size.
    ///   2. Allocate `count = byteSize / MemoryLayout<T>.size` elements and
    ///      AudioObjectGetPropertyData into them.
    ///
    /// WHY `throws` here (vs. the Optional scalar read)?  These lists are
    /// load-bearing for enumeration — a failure usually means a real Core Audio
    /// problem the caller should surface, and the spec's public API declares
    /// this one as `throws`. We wrap the OSStatus via `AudioStackError.check`
    /// (defined in Models.swift) so the error carries a human-readable context.
    ///
    /// EDGE CASE: a size of 0 (empty list, perfectly legal) returns `[]` without
    /// a second call — calling AudioObjectGetPropertyData with a zero-length
    /// buffer is unnecessary and some drivers dislike a nil/empty outData.
    static func readArray<T>(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress,
        type: T.Type
    ) throws -> [T] {
        // Step 1: ask for the byte size.
        var dataSize: UInt32 = 0
        try AudioStackError.check(
            AudioObjectGetPropertyDataSize(
                objectID,
                &address,
                0,            // no qualifier
                nil,
                &dataSize
            ),
            "AudioObjectGetPropertyDataSize(\(address.mSelector.fourCharCodeString))"
        )

        // Convert bytes -> element count. Integer division is intentional and
        // exact for well-formed properties (Core Audio reports a multiple of
        // the element size).
        let stride = MemoryLayout<T>.stride
        guard stride > 0 else { return [] }
        let count = Int(dataSize) / stride
        guard count > 0 else { return [] }

        // Step 2: allocate exactly `count` elements and fill them.
        //
        // We use Array(unsafeUninitializedCapacity:) so the storage is a single
        // contiguous block (Core Audio writes a C array straight into it) and so
        // we never read uninitialised memory — we set `initializedCount` to the
        // number of elements Core Audio actually delivered.
        var ioDataSize = dataSize
        let result = try [T](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            let status = AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &ioDataSize,          // in: our capacity in bytes; out: bytes written
                buffer.baseAddress!   // safe: count > 0 guarantees a non-nil base
            )
            try AudioStackError.check(
                status,
                "AudioObjectGetPropertyData(\(address.mSelector.fourCharCodeString))"
            )
            // Trust the byte count Core Audio reports back, clamped to capacity,
            // in case the list shrank between the size query and the data read
            // (devices can appear/disappear between the two calls).
            initializedCount = min(Int(ioDataSize) / stride, count)
        }
        return result
    }

    // MARK: CFString Read

    /// Reads a CFString-typed property (device name 'lnam', device UID 'uid ',
    /// process bundle ID 'pbid', ...) and returns it as a Swift `String?`.
    ///
    /// THE #1 MEMORY BUG THIS AVOIDS: CFString-typed Core Audio properties are
    /// returned **+1 retained** — the caller owns a reference. Core Audio writes
    /// the `CFStringRef` (a pointer) into the `outData` slot we provide. If we
    /// pulled it out as an `Unmanaged<CFString>` and forgot `takeRetainedValue`,
    /// we'd leak; if we used `takeUnretainedValue`, we'd over-release.
    ///
    /// The clean Swift idiom used here:
    ///   * declare `var cfString: CFString?` (an *owning* optional reference),
    ///   * pass its address as `outData`,
    ///   * bridge the result `as String?`.
    /// ARC treats `cfString` as a strong reference holding the +1 the API gave
    /// us, and releases it when the local goes out of scope. No manual
    /// Unmanaged juggling, no leak.
    ///
    /// EMPTY-STRING == nil: several properties (e.g. bundle ID for a daemon with
    /// no bundle) come back as an empty CFString rather than a failure. The spec
    /// says treat empty as nil, so callers don't have to special-case "".
    static func readCFString(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress
    ) -> String? {
        // Storage for the returned pointer. CFString? is a class-bound optional;
        // its in-memory representation is exactly one pointer wide, which is what
        // Core Audio expects to write for a CFStringRef payload.
        var cfString: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                ptr           // outData receives the +1 CFStringRef
            )
        }

        // ARC now owns the +1 reference via `cfString`; bridging to String makes
        // an independent Swift copy and `cfString` is released at scope exit.
        guard status == noErr, let swiftString = cfString as String?, !swiftString.isEmpty else {
            return nil
        }
        return swiftString
    }

    // MARK: AudioStreamBasicDescription Read

    /// Reads an `AudioStreamBasicDescription` (the canonical "what does this
    /// stream look like" struct: sample rate, format flags, channels, bytes).
    ///
    /// Primary use: `kAudioTapPropertyFormat` ('tfmt') on a *tap* object to learn
    /// the captured stream's format, from which ProcessTap derives the
    /// AVAudioFormat that must match the ring buffer and the AVAudioSourceNode.
    ///
    /// This is functionally a fixed-size scalar read, but it gets its own helper
    /// because (a) the spec's public API lists it explicitly and (b) it throws —
    /// an unreadable tap format is a hard error (AudioStackError.invalidTapFormat
    /// is raised by the caller; here we surface the OSStatus with context).
    ///
    /// We seed the struct zeroed so a partial read can never leave stale stack
    /// garbage in the fields.
    static func readASBD(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress
    ) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = withUnsafeMutablePointer(to: &asbd) { ptr -> OSStatus in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                ptr
            )
        }

        try AudioStackError.check(
            status,
            "AudioObjectGetPropertyData(\(address.mSelector.fourCharCodeString) ASBD)"
        )
        return asbd
    }

    // MARK: Qualifier Read

    /// Reads a scalar value of type `T` while supplying an *input* qualifier of
    /// type `Q`.
    ///
    /// WHY qualifiers exist: a few Core Audio properties are really functions —
    /// they need an input argument the caller passes in the qualifier slot, not
    /// in the object ID. The canonical case in this app is
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject` ('id2p') on the
    /// system object: the *PID goes in the qualifier* (`inQualifierData`), and
    /// the resulting process-object `AudioObjectID` comes out in `outData`.
    /// Putting the PID in the object ID (a frequent mistake) or in `outData`
    /// would be wrong.
    ///
    /// IMPORTANT CALLER CONTRACT (TranslatePID gotcha): an unknown PID is NOT an
    /// error. Core Audio returns `noErr` with `outData == kAudioObjectUnknown`
    /// (0). So callers MUST check the returned value, not just success. This
    /// helper returns the value (which may legitimately be the `def` you seeded,
    /// e.g. kAudioObjectUnknown) on success and `nil` only on a real failing
    /// OSStatus.
    ///
    /// POINTER SAFETY: both the qualifier and the output get stable addresses
    /// for the duration of the single call via nested `withUnsafe*Pointer`. We
    /// take the qualifier by `var` (a mutable local copy) because Core Audio
    /// wants a raw pointer to it; it does not mutate the qualifier, but
    /// `withUnsafePointer(to:)` requires an addressable storage location.
    static func readWithQualifier<Q, T>(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress,
        qualifier: Q,
        default def: T
    ) -> T? {
        var qualifierValue = qualifier
        var value = def
        var dataSize = UInt32(MemoryLayout<T>.size)
        let qualifierSize = UInt32(MemoryLayout<Q>.size)

        let status = withUnsafePointer(to: &qualifierValue) { qualifierPtr -> OSStatus in
            withUnsafeMutablePointer(to: &value) { valuePtr -> OSStatus in
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    qualifierSize,              // inQualifierDataSize
                    qualifierPtr,               // inQualifierData (the INPUT argument)
                    &dataSize,                  // ioDataSize
                    valuePtr                    // outData (the RESULT)
                )
            }
        }

        guard status == noErr else { return nil }
        return value
    }

    // MARK: Scalar Write

    /// Writes a single fixed-size POD value of type `T` to `objectID`.
    ///
    /// Provided for completeness / symmetry so that no other module hand-rolls
    /// `AudioObjectSetPropertyData` either (the spec's mandate: this file is the
    /// only place that touches the AudioObject* C-API). Settable hardware
    /// properties (e.g. a device's nominal sample rate, or toggling a property
    /// during aggregate setup) flow through here.
    ///
    /// Throws so the caller learns precisely which write failed (the OSStatus is
    /// wrapped with the selector four-char-code in the context string).
    static func writeScalar<T>(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress,
        value: T
    ) throws {
        var mutableValue = value
        let dataSize = UInt32(MemoryLayout<T>.size)

        let status = withUnsafePointer(to: &mutableValue) { ptr -> OSStatus in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,            // no qualifier on the write path used here
                nil,
                dataSize,
                ptr
            )
        }

        try AudioStackError.check(
            status,
            "AudioObjectSetPropertyData(\(address.mSelector.fourCharCodeString))"
        )
    }

    // MARK: Existence Check

    /// Returns whether `objectID` has the property at `address`.
    ///
    /// Thin wrapper over `AudioObjectHasProperty`, useful before a read that
    /// might not apply to a given object (some devices lack a UID, some process
    /// objects lack certain selectors). Pure boolean query, never throws.
    ///
    /// NOTE: the Swift CoreAudio overlay imports `AudioObjectHasProperty` as
    /// returning a native `Bool` (the C `Boolean` is bridged for us), so we
    /// return it directly — calling `.boolValue` on it is a compile error.
    static func hasProperty(
        _ objectID: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress
    ) -> Bool {
        AudioObjectHasProperty(objectID, &address)
    }
}
