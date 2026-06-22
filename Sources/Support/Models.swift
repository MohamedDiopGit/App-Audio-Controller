// Support/Models.swift
//
// SINGLE SOURCE OF TRUTH for the shared value types that every module in the
// app passes around. This file deliberately contains NO Core Audio calls — it
// only imports the types (AudioObjectID, pid_t, AudioStreamBasicDescription-adjacent
// scalars, OSStatus, noErr) so that the model shapes are decoupled from the
// property-reading machinery that lives in Support/CoreAudioHelpers.swift.
//
// WHY two imports:
//   * CoreAudio  -> gives us AudioObjectID (== UInt32), pid_t (Int32), OSStatus,
//                   and the noErr (== 0) success sentinel used by EVERY Core
//                   Audio C function. These are the lingua franca of the HAL.
//   * AppKit     -> gives us NSImage so AudioProcessInfo can carry an app icon
//                   (sourced from NSRunningApplication.icon) for the picker UI.
//
// These types are intentionally plain value types (struct/enum). They are safe
// to hand across the @MainActor boundary in AudioTapManager and to bind to in
// SwiftUI. The reference type they contain (NSImage) is immutable in practice
// here (we never mutate the icon), so Hashable/Equatable are defined on stable
// identity keys (the AudioObjectID / device UID), NOT on the icon.

import CoreAudio
import AppKit

/// A process that can be tapped (an app currently connected to the HAL).
///
/// IMPORTANT IDENTITY SEMANTICS (the #1 Core Audio Process Tap bug):
/// `id` is the AudioObjectID of the **PROCESS OBJECT** (class
/// `kAudioProcessClassID`), obtained via
/// `kAudioHardwarePropertyTranslatePIDToProcessObject`. It is NOT a `pid_t`.
/// `CATapDescription(stereoMixdownOfProcesses:)` expects an array of these
/// process-object AudioObjectIDs — passing a raw pid (cast to AudioObjectID)
/// yields a non-functional / silent tap. The `pid` field below is kept ONLY
/// to join to `NSRunningApplication(processIdentifier:)` for the friendly
/// name + icon; it must never be put into a CATapDescription.
struct AudioProcessInfo: Identifiable, Hashable {
    /// AudioObjectID of the PROCESS OBJECT (class kAudioProcessClassID), NOT a pid.
    let id: AudioObjectID
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let isRunningOutput: Bool
    /// Effective activation policy of the displayed app. For helper/renderer
    /// processes this is the PARENT app's policy, so Chrome helpers inherit
    /// `.regular` from the main Chrome app. Used to filter out system UI
    /// processes (`.accessory`, `.prohibited`) that happen to have icons.
    let activationPolicy: NSApplication.ActivationPolicy

    // Equality/hashing are keyed ONLY on `id` (the process-object AudioObjectID),
    // which is the stable identity for the lifetime of the process's HAL
    // connection. We deliberately exclude `name`/`icon` (cosmetic, may refresh)
    // and `isRunningOutput` (a transient live flag) so that a process compares
    // equal to itself across enumeration refreshes even if its running state
    // toggles. NSImage is also not Hashable in a meaningful value sense, so it
    // must not participate in the hash.
    static func == (lhs: AudioProcessInfo, rhs: AudioProcessInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A hardware output-capable audio device.
///
/// IDENTITY SEMANTICS: `id` (the numeric AudioDeviceID == AudioObjectID) is
/// fast to use at runtime but is NOT stable across reboots or device
/// reconnects — the HAL reassigns it freely. Therefore persistence (and the
/// aggregate device's main-sub-device key / sub-device list) must key off the
/// `uid` string (`kAudioDevicePropertyDeviceUID`), which IS stable. Equality
/// and hashing are keyed on `uid` for exactly this reason: two enumerations
/// that hand back the same physical device with a freshly-assigned numeric id
/// still compare equal, so a persisted selection survives a refresh.
struct AudioOutputDevice: Identifiable, Hashable {
    /// AudioDeviceID (== AudioObjectID). Numeric, NOT stable across reboots; persist `uid` instead.
    let id: AudioObjectID
    /// Stable UID string (kAudioDevicePropertyDeviceUID) used for persistence and as the
    /// aggregate device's main sub-device key.
    let uid: String
    let name: String

    static func == (lhs: AudioOutputDevice, rhs: AudioOutputDevice) -> Bool { lhs.uid == rhs.uid }
    func hash(into hasher: inout Hasher) { hasher.combine(uid) }
}

/// Errors surfaced by the audio stack.
///
/// `osStatus` carries the raw Core Audio `OSStatus` plus a human-readable
/// `context` describing WHICH call failed (e.g. "AudioHardwareCreateProcessTap"),
/// because a bare OSStatus four-char-code is otherwise inscrutable when it
/// bubbles up to the UI or a log. All the helpers in CoreAudioHelpers.swift and
/// the engine modules throw this single error type so callers have one thing to
/// catch.
enum AudioStackError: Error {
    case osStatus(OSStatus, context: String)
    case processNotFound(pid_t)
    case deviceNotFound(uid: String)
    case invalidTapFormat
    case unsupportedOS            // < macOS 14.4
    case engineStartFailed(underlying: Error)
}

extension AudioStackError {
    /// Helper to wrap a non-noErr OSStatus.
    ///
    /// WHY this exists: virtually every Core Audio C call returns `OSStatus`
    /// where `noErr` (== 0) means success and anything else is a failure. This
    /// collapses the ubiquitous `guard status == noErr else { throw ... }`
    /// boilerplate into one throwing call so each bridge site reads as a single
    /// line and always attaches a descriptive `context`. Other modules call it
    /// as e.g. `try AudioStackError.check(status, "AudioObjectGetPropertyData")`.
    static func check(_ status: OSStatus, _ context: String) throws {
        guard status == noErr else { throw AudioStackError.osStatus(status, context: context) }
    }
}
