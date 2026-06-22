// System/AudioProcessEnumerator.swift
//
// Enumerates running audio "process objects" exposed by the HAL on macOS 14+,
// filters to those producing output audio, and joins each to its NSRunningApplication
// for a friendly name + icon. Produces [AudioProcessInfo] for the rest of the audio
// stack (notably ProcessTap, which needs the PROCESS-OBJECT AudioObjectID — never a pid).
//
// WHY this file exists as a thin layer over Core Audio:
//   The modern process-tap API (CATapDescription / AudioHardwareCreateProcessTap) taps
//   audio by PROCESS-OBJECT AudioObjectID, NOT by pid_t. The #1 integration bug in this
//   whole codebase is passing a raw pid where a process-object id is required. This file
//   owns the pid <-> process-object translation and the per-process property reads, so
//   no other module has to get that contract right.
//
// All raw AudioObjectGetPropertyData / size calls are funneled through CoreAudioHelpers
// (Support/CoreAudioHelpers.swift) per the architecture's "single C-interop choke point"
// rule. The one exception is kAudioHardwarePropertyTranslatePIDToProcessObject, which
// needs a QUALIFIER (the pid goes in inQualifierData, not outData) — that path is exposed
// by CoreAudioHelpers as `readWithQualifier`, which we use here.

import CoreAudio
import AppKit

/// Enumerates HAL process objects and maps them to friendly app metadata.
///
/// macOS 14.0+: the process-object selectors (`kAudioHardwarePropertyProcessObjectList`,
/// `kAudioHardwarePropertyTranslatePIDToProcessObject`, and the per-process `kAudioProcessProperty*`
/// selectors) do not exist in pre-14 SDKs. Enumeration is a low-privilege operation (no TCC
/// prompt); only the later tap-capture flow requires the audio-capture entitlement, so this
/// type is gated at 14.0 even though `ProcessTap` is gated at 14.4.
@available(macOS 14.0, *)
enum AudioProcessEnumerator {

    // MARK: - Public API

    /// All HAL process objects currently producing OUTPUT audio, mapped to display metadata.
    ///
    /// This is the list the UI shows as "tappable apps": we want apps that are actively
    /// driving an output stream (e.g. a music player, a browser playing video). Note that
    /// `kAudioProcessPropertyIsRunningOutput` reports active output IO, NOT audible/non-zero
    /// samples — a muted-but-live stream still reports 1. There is no public property for
    /// "actual sound", so this is the best available filter.
    static func runningOutputProcesses() throws -> [AudioProcessInfo] {
        try allProcesses().filter { $0.isRunningOutput }
    }

    /// Every HAL process object, regardless of whether it is currently producing output.
    ///
    /// Useful as a fallback in the UI (a target app may be momentarily silent yet still
    /// worth tapping, because the aggregate device is created with TapAutoStart=true and
    /// will begin delivering frames once the app resumes output).
    static func allProcesses() throws -> [AudioProcessInfo] {
        let objectIDs = try processObjectIDs()

        var infos: [AudioProcessInfo] = []
        infos.reserveCapacity(objectIDs.count)

        for objectID in objectIDs where objectID != AudioObjectID(kAudioObjectUnknown) {
            let pid = readPID(objectID)
            guard pid > 0 else { continue }

            let bundleID = readBundleID(objectID)
            let isRunningOutput = readIsRunningOutput(objectID)

            let app = NSRunningApplication(processIdentifier: pid)
            var name   = app?.localizedName ?? bundleID ?? "PID \(pid)"
            var icon   = app?.icon
            // Default to .prohibited when NSRunningApplication returns nil (the
            // process is a background daemon with no user-facing app entry). This
            // is the safe direction: we'd rather miss an obscure app than spam the
            // list with system internals. The value is overridden below for helper
            // processes that are aliased to their parent app.
            var policy = app?.activationPolicy ?? NSApplication.ActivationPolicy.prohibited

            // ── Parent-app aliasing ────────────────────────────────────────────
            // Multi-process browsers (Chrome, Firefox, Safari) route audio through
            // renderer/helper subprocesses. Their bundle IDs look like
            // "com.google.Chrome.helper" or "org.mozilla.firefox.renderer". The
            // subprocess has an ugly name and no icon; we look up the PARENT app
            // so the user sees "Google Chrome" with the Chrome icon instead.
            // Crucially we also use the PARENT's activation policy — Chrome helpers
            // are .prohibited themselves, but the parent Chrome is .regular, so
            // the helper correctly passes the .regular filter downstream.
            if let bid = bundleID,
               let parentBID = helperParentBundleID(bid),
               let parentApp = NSRunningApplication
                   .runningApplications(withBundleIdentifier: parentBID).first {
                name   = parentApp.localizedName ?? name
                icon   = parentApp.icon ?? icon
                policy = parentApp.activationPolicy
            }

            infos.append(
                AudioProcessInfo(
                    id: objectID,
                    pid: pid,
                    name: name,
                    bundleID: bundleID,
                    icon: icon,
                    isRunningOutput: isRunningOutput,
                    activationPolicy: policy
                )
            )
        }

        // ── Consolidate per parent app ─────────────────────────────────────────
        // After aliasing, Chrome helpers all show as "Google Chrome". We now
        // collapse the per-family list so the UI shows ONE entry per app:
        //   • if helpers are producing audio → show active helpers, hide main process
        //   • if helpers are paused          → show one representative helper, hide main
        //   • if no helpers at all           → show the main process as-is
        infos = consolidateByParentApp(infos)

        // Stable ordering: output-active first, then alphabetically.
        infos.sort { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return infos
    }

    // MARK: - Helper / renderer detection

    /// If `bundleID` looks like a subprocess of a parent app, returns the parent
    /// bundle ID; otherwise returns nil.
    ///
    /// Patterns handled (case-insensitive on the suffix component):
    ///   "com.google.Chrome.helper"          → "com.google.Chrome"
    ///   "com.google.Chrome.helper.EH"       → "com.google.Chrome"
    ///   "org.mozilla.firefox.renderer"      → "org.mozilla.firefox"
    ///   "com.apple.WebKit.WebContent"       → detected via "webcontent" keyword
    ///   "com.apple.Safari.SafariRendering"  → detected via "rendering"
    private static func helperParentBundleID(_ bundleID: String) -> String? {
        let helperKeywords: Set<String> = [
            "helper", "renderer", "plugin", "gpu", "xpc",
            "sandbox", "webcontent", "rendering", "crashpad",
        ]
        let parts = bundleID.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        // "com.app.helper" or "com.app.renderer"
        if helperKeywords.contains(parts.last!.lowercased()) {
            let parent = parts.dropLast().joined(separator: ".")
            return parent.isEmpty ? nil : parent
        }
        // "com.app.helper.EH" — keyword is second-to-last
        if parts.count >= 3,
           helperKeywords.contains(parts[parts.count - 2].lowercased()) {
            let parent = parts.dropLast(2).joined(separator: ".")
            return parent.isEmpty ? nil : parent
        }
        return nil
    }

    /// Collapses per-family (main + helpers) entries to one visible row per app.
    private static func consolidateByParentApp(_ infos: [AudioProcessInfo]) -> [AudioProcessInfo] {

        // Map each entry to its "family key" — parent bundle ID for helpers, own bundle ID otherwise.
        func familyKey(_ info: AudioProcessInfo) -> String {
            guard let bid = info.bundleID else { return "pid:\(info.pid)" }
            return helperParentBundleID(bid) ?? bid
        }

        let families = Dictionary(grouping: infos, by: familyKey)
        var result: [AudioProcessInfo] = []

        for (_, members) in families {
            let helpers = members.filter { helperParentBundleID($0.bundleID ?? "") != nil }
            let mains   = members.filter { helperParentBundleID($0.bundleID ?? "") == nil }

            if helpers.isEmpty {
                // No subprocesses: show the main process as-is.
                result.append(contentsOf: mains)
            } else {
                // Subprocesses exist. Prefer them over the main process because the
                // main Chrome/Firefox process typically never produces audio itself.
                let active = helpers.filter { $0.isRunningOutput }
                if !active.isEmpty {
                    // Show every active helper (one per tab producing audio).
                    result.append(contentsOf: active)
                } else {
                    // All paused: show one representative (lowest PID = most stable).
                    if let rep = helpers.min(by: { $0.pid < $1.pid }) {
                        result.append(rep)
                    }
                }
                // Main process is intentionally dropped — it never produces audio.
            }
        }

        return result
    }

    /// Translates a Unix `pid_t` into the HAL PROCESS-OBJECT `AudioObjectID`.
    ///
    /// This is the single most error-prone Core Audio contract in the codebase, so it lives
    /// here and is reused by `ProcessTap` to build `CATapDescription(stereoMixdownOfProcesses:)`.
    ///
    /// Mechanics (see `kAudioHardwarePropertyTranslatePIDToProcessObject`):
    ///   - Query the SYSTEM object (kAudioObjectSystemObject), global scope, main element.
    ///   - The pid goes in the QUALIFIER (inQualifierDataSize / inQualifierData), NOT in outData.
    ///     outData receives the resulting AudioObjectID.
    ///   - An UNKNOWN pid is NOT reported as an OSStatus error: the call returns noErr with
    ///     outData == kAudioObjectUnknown (0). We therefore check the VALUE, not just the status,
    ///     and normalize "not found" to kAudioObjectUnknown for the caller to detect.
    ///
    /// Returns `kAudioObjectUnknown` (0) when no process object exists for the pid.
    static func processObjectID(forPID pid: pid_t) -> AudioObjectID {
        var address = CoreAudio.address(
            kAudioHardwarePropertyTranslatePIDToProcessObject
            // scope = global, element = main are the defaults and are correct for this selector.
        )

        // The pid is passed by value as the qualifier. CoreAudioHelpers.readWithQualifier
        // wires inQualifierDataSize = MemoryLayout<pid_t>.size and inQualifierData = &qualifier,
        // and reads back a scalar AudioObjectID into `default`.
        let result = CoreAudio.readWithQualifier(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifier: pid,
            default: AudioObjectID(kAudioObjectUnknown)
        )

        // `result` is nil only if the helper saw a hard OSStatus failure. Either way,
        // collapse to the unambiguous sentinel so the caller has one thing to test.
        guard let objectID = result, objectID != AudioObjectID(kAudioObjectUnknown) else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return objectID
    }

    // MARK: - Process list

    /// Reads the full array of process-object AudioObjectIDs from the SYSTEM object.
    ///
    /// `kAudioHardwarePropertyProcessObjectList` ('prs#') is queried on
    /// kAudioObjectSystemObject (global scope, main element) and returns a variable-length
    /// C array of AudioObjectID. CoreAudioHelpers.readArray performs the standard
    /// size-then-read dance (AudioObjectGetPropertyDataSize, count = dataSize / sizeof(T)).
    private static func processObjectIDs() throws -> [AudioObjectID] {
        var address = CoreAudio.address(kAudioHardwarePropertyProcessObjectList)
        return try CoreAudio.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            type: AudioObjectID.self
        )
    }

    // MARK: - Per-process property reads

    /// Reads `kAudioProcessPropertyPID` ('ppid') — the Unix pid backing this process object.
    ///
    /// Data type is `pid_t` (Int32). We seed the default with -1 so a failed read is
    /// distinguishable from a real pid (real pids are positive) and gets filtered upstream.
    private static func readPID(_ objectID: AudioObjectID) -> pid_t {
        var address = CoreAudio.address(kAudioProcessPropertyPID)
        return CoreAudio.readScalar(objectID, &address, default: pid_t(-1)) ?? pid_t(-1)
    }

    /// Reads `kAudioProcessPropertyIsRunningOutput` ('piro') — 1 if the process has at least
    /// one ACTIVE OUTPUT stream and audio IO is in progress.
    ///
    /// The property is a UInt32 (0/1). We treat any read failure as "not running output"
    /// (false) rather than throwing, so one flaky process object cannot blank the whole list.
    private static func readIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = CoreAudio.address(kAudioProcessPropertyIsRunningOutput)
        let value = CoreAudio.readScalar(objectID, &address, default: UInt32(0)) ?? 0
        return value != 0
    }

    /// Reads `kAudioProcessPropertyBundleID` ('pbid') — the process's bundle identifier.
    ///
    /// The property returns a CFString that is +1-retained by the API. CoreAudioHelpers.readCFString
    /// bridges it `as String?` so ARC releases that +1 reference (avoiding a leak) and maps the
    /// empty string to nil. Processes without a bundle (daemons, helpers) legitimately have no
    /// bundle id, so nil is expected and is handled by the name-fallback chain in allProcesses().
    private static func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = CoreAudio.address(kAudioProcessPropertyBundleID)
        return CoreAudio.readCFString(objectID, &address)
    }
}