//  AudioDeviceSettingsManager.swift
//  Enumerates ALL audio devices (input, output, I/O), reads and writes
//  volume, balance, sample rate, and default-device selection via Core Audio.
//  Property listeners keep the UI in sync with changes made elsewhere
//  (keyboard volume keys, other apps, etc.).

import Foundation
import CoreAudio
import os

// MARK: - Model

struct DeviceInfo: Identifiable {
    let id: AudioDeviceID          // AudioObjectID
    let uid: String
    let name: String
    let hasInput:  Bool
    let hasOutput: Bool

    // Live-mutable controls (updated by manager, settable via setters)
    var outputVolume: Float = 0.5
    var inputVolume:  Float = 0.5
    var balance: Float = 0.5       // 0 = full-left, 0.5 = centre, 1 = full-right
    var sampleRate: Double = 44100
    var availableSampleRates: [Double] = []

    // Capability flags (determined once at init)
    let canSetOutputVolume: Bool
    let canSetInputVolume:  Bool
    let canSetBalance:      Bool
    let canSetSampleRate:   Bool

    var isDefaultOutput: Bool = false
    var isDefaultInput:  Bool = false
}

// MARK: - Manager

@MainActor
final class AudioDeviceSettingsManager: ObservableObject {

    @Published var devices: [DeviceInfo] = []

    var inputDevices:  [DeviceInfo] { devices.filter { $0.hasInput  && !$0.hasOutput } }
    var outputDevices: [DeviceInfo] { devices.filter { !$0.hasInput &&  $0.hasOutput } }
    var ioDevices:     [DeviceInfo] { devices.filter { $0.hasInput  &&  $0.hasOutput } }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let log = Logger(subsystem: "AppAudioController", category: "DeviceSettings")

    init() {
        refresh()
        installListeners()
    }

    // MARK: - Enumeration

    func refresh() {
        let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultIn  = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr
        else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            0, nil, &dataSize, &ids) == noErr
        else { return }

        devices = ids.compactMap { deviceID -> DeviceInfo? in
            guard deviceID != 0 else { return nil }
            let name    = readString(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "Device \(deviceID)"
            let uid     = readString(deviceID, kAudioDevicePropertyDeviceUID) ?? UUID().uuidString
            let inCh    = channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
            let outCh   = channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
            guard inCh > 0 || outCh > 0 else { return nil }

            let canSetOutVol = isSettable(deviceID, kAudioDevicePropertyVolumeScalar,
                                          scope: kAudioObjectPropertyScopeOutput)
            let canSetInVol  = isSettable(deviceID, kAudioDevicePropertyVolumeScalar,
                                          scope: kAudioObjectPropertyScopeInput)
            let canSetBal    = isSettable(deviceID, kAudioDevicePropertyStereoPan,
                                          scope: kAudioObjectPropertyScopeOutput)
            let canSetSR     = isSettable(deviceID, kAudioDevicePropertyNominalSampleRate,
                                          scope: kAudioObjectPropertyScopeGlobal)

            var info = DeviceInfo(
                id: deviceID, uid: uid, name: name,
                hasInput: inCh > 0, hasOutput: outCh > 0,
                canSetOutputVolume: canSetOutVol,
                canSetInputVolume:  canSetInVol,
                canSetBalance:      canSetBal,
                canSetSampleRate:   canSetSR)

            if outCh > 0 { info.outputVolume = readVolume(deviceID, scope: kAudioObjectPropertyScopeOutput) }
            if inCh  > 0 { info.inputVolume  = readVolume(deviceID, scope: kAudioObjectPropertyScopeInput)  }
            if canSetBal  { info.balance      = readBalance(deviceID) }
            info.sampleRate = readSampleRate(deviceID)
            info.availableSampleRates = readAvailableSampleRates(deviceID)
            info.isDefaultOutput = deviceID == defaultOut
            info.isDefaultInput  = deviceID == defaultIn
            return info
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Setters

    func setOutputVolume(_ v: Float, for id: AudioDeviceID) {
        writeVolume(max(0, min(1, v)), on: id, scope: kAudioObjectPropertyScopeOutput)
        update(id) { $0.outputVolume = max(0, min(1, v)) }
    }

    func setInputVolume(_ v: Float, for id: AudioDeviceID) {
        writeVolume(max(0, min(1, v)), on: id, scope: kAudioObjectPropertyScopeInput)
        update(id) { $0.inputVolume = max(0, min(1, v)) }
    }

    func setBalance(_ b: Float, for id: AudioDeviceID) {
        var val = max(0, min(1, b))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStereoPan,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
        update(id) { $0.balance = val }
    }

    func setSampleRate(_ rate: Double, for id: AudioDeviceID) {
        var r = rate
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil,
                                               UInt32(MemoryLayout<Float64>.size), &r)
        if status == noErr { update(id) { $0.sampleRate = rate } }
    }

    func setAsDefaultOutput(_ id: AudioDeviceID) {
        var devID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
        for i in devices.indices { devices[i].isDefaultOutput = devices[i].id == id }
    }

    func setAsDefaultInput(_ id: AudioDeviceID) {
        var devID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
        for i in devices.indices { devices[i].isDefaultInput = devices[i].id == id }
    }

    // MARK: - Private helpers

    private func update(_ id: AudioDeviceID, mutation: (inout DeviceInfo) -> Void) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        mutation(&devices[idx])
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func channelCount(_ id: AudioDeviceID,
                               scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return 0 }
        let abl = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let ptr = UnsafeMutableAudioBufferListPointer(abl)
        return ptr.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func readString(_ id: AudioDeviceID,
                             _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfStr: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfStr) == noErr else { return nil }
        let s = cfStr as String
        return s.isEmpty ? nil : s
    }

    private func isSettable(_ id: AudioDeviceID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func readVolume(_ id: AudioDeviceID,
                             scope: AudioObjectPropertyScope) -> Float {
        var vol = Float(0.5)
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: scope, mElement: element)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &vol) == noErr { return vol }
        }
        return 0.5
    }

    private func writeVolume(_ v: Float, on id: AudioDeviceID,
                              scope: AudioObjectPropertyScope) {
        var vol = v
        let size = UInt32(MemoryLayout<Float32>.size)
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: scope, mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, &vol)
            if element == kAudioObjectPropertyElementMain { return }
        }
    }

    private func readBalance(_ id: AudioDeviceID) -> Float {
        var val = Float(0.5)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStereoPan,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val)
        return val
    }

    private func readSampleRate(_ id: AudioDeviceID) -> Double {
        var rate = Float64(44100)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    private func readAvailableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
                                       count: count)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        // For most hardware, mMinimum == mMaximum for each entry (a fixed rate).
        let rates = ranges.compactMap { $0.mMinimum == $0.mMaximum ? $0.mMinimum : nil }
        return Array(Set(rates)).sorted()
    }

    // MARK: - Listeners

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listenerBlock = block

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ]
        for sel in selectors {
            var addr = AudioObjectPropertyAddress(mSelector: sel,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &addr, .main, block)
        }
    }
}
