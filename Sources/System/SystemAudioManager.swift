//  SystemAudioManager.swift
//  System
//
//  Reads and writes the macOS system output volume + microphone input volume
//  via Core Audio. Registers property listeners so the UI reflects changes
//  made outside the app (e.g. keyboard volume keys, Control Centre).
//

import Foundation
import CoreAudio
import os

@MainActor
final class SystemAudioManager: ObservableObject {

    // MARK: - Published state

    @Published var outputVolume:  Float = 0.5
    @Published var inputVolume:   Float = 0.5
    @Published var isOutputMuted: Bool  = false
    /// False when the default input device has no software-controllable gain.
    @Published var hasInputVolumeControl: Bool = false

    // MARK: - Private

    private var outputDeviceID: AudioDeviceID = 0
    private var inputDeviceID:  AudioDeviceID = 0
    /// Strong ref keeps the block alive for the duration of the listener.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private let log = Logger(subsystem: "AppAudioController", category: "SystemAudio")

    // MARK: - Init / refresh

    init() { refresh() }

    /// Re-reads the default devices and their volumes. Call when the default
    /// device changes (e.g. user plugs in headphones).
    func refresh() {
        outputDeviceID = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        inputDeviceID  = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        hasInputVolumeControl = isSettable(on: inputDeviceID,
                                           scope: kAudioObjectPropertyScopeInput)
        refreshVolumes()
        installListeners()
    }

    func refreshVolumes() {
        outputVolume  = readVolume(on: outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        inputVolume   = readVolume(on: inputDeviceID,  scope: kAudioObjectPropertyScopeInput)
        isOutputMuted = readMute(on: outputDeviceID,   scope: kAudioObjectPropertyScopeOutput)
    }

    // MARK: - Setters

    func setOutputVolume(_ v: Float) {
        let c = v.clamped
        writeVolume(c, on: outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        outputVolume = c
    }

    func setInputVolume(_ v: Float) {
        let c = v.clamped
        writeVolume(c, on: inputDeviceID, scope: kAudioObjectPropertyScopeInput)
        inputVolume = c
    }

    func toggleOutputMute() {
        let next: UInt32 = isOutputMuted ? 0 : 1
        writeMute(next, on: outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        isOutputMuted = next != 0
    }

    // MARK: - Core Audio property helpers

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &id)
        return id
    }

    /// Read scalar volume (0–1) trying element 0 first, then channels 1 and 2.
    private func readVolume(on deviceID: AudioDeviceID,
                            scope: AudioObjectPropertyScope) -> Float {
        var vol = Float(0.5)
        for element: AudioObjectPropertyElement in
            [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope, mElement: element)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return 0.5
    }

    /// Write scalar volume, trying the master channel first then per-channel.
    private func writeVolume(_ v: Float,
                             on deviceID: AudioDeviceID,
                             scope: AudioObjectPropertyScope) {
        var vol = v
        let size = UInt32(MemoryLayout<Float32>.size)
        for element: AudioObjectPropertyElement in
            [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope, mElement: element)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
            // If element 0 succeeded, no need to set per-channel.
            if element == kAudioObjectPropertyElementMain { return }
        }
    }

    private func readMute(on deviceID: AudioDeviceID,
                          scope: AudioObjectPropertyScope) -> Bool {
        var mute = UInt32(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &mute)
        return mute != 0
    }

    private func writeMute(_ v: UInt32,
                           on deviceID: AudioDeviceID,
                           scope: AudioObjectPropertyScope) {
        var mute = v
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &mute)
    }

    /// Returns true if the device has a settable scalar volume on the given scope.
    private func isSettable(on deviceID: AudioDeviceID,
                            scope: AudioObjectPropertyScope) -> Bool {
        for element: AudioObjectPropertyElement in
            [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope, mElement: element)
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr {
                return settable.boolValue
            }
        }
        return false
    }

    // MARK: - Property listeners

    private func installListeners() {
        // One shared block handles any volume/mute change on either device.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshVolumes()
        }
        listenerBlock = block  // keep alive

        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute,
        ]
        for sel in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: sel,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(outputDeviceID, &addr, .main, block)
        }
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(inputDeviceID, &inputAddr, .main, block)
    }
}

private extension Float {
    var clamped: Float { max(0, min(1, self)) }
}
