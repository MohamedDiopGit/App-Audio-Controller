//  DevicesSettingsView.swift
//  Audio Devices settings window — modelled after Audio MIDI Setup.
//  Two-column layout: sidebar (device list grouped by type) + detail panel.

import SwiftUI
import AppKit
import CoreAudio

@available(macOS 13.0, *)
struct DevicesSettingsView: View {
    @EnvironmentObject var settings: AudioDeviceSettingsManager
    @State private var selectedID: AudioDeviceID? = nil

    var body: some View {
        HSplitView {
            // ── Sidebar ──────────────────────────────────────────────────
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            // ── Detail panel ─────────────────────────────────────────────
            if let id = selectedID,
               let device = settings.devices.first(where: { $0.id == id }) {
                DeviceDetailView(device: device)
                    .environmentObject(settings)
                    .frame(minWidth: 380)
                    .id(id)  // force full re-render when selection changes
            } else {
                Text("Select a device")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .onAppear {
            settings.refresh()
            if selectedID == nil { selectedID = settings.devices.first?.id }
            // The app is an LSUIElement agent — its windows don't come to front
            // automatically when another app is active. Activate explicitly so
            // the window always appears on top of VS Code / other frontmost apps.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedID) {
            deviceSection("Input Devices",   systemImage: "mic",          devices: settings.inputDevices)
            deviceSection("Output Devices",  systemImage: "speaker.wave.2", devices: settings.outputDevices)
            deviceSection("I/O Devices",     systemImage: "dot.radiowaves.left.and.right", devices: settings.ioDevices)
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { settings.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh device list")
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ title: String,
                                systemImage: String,
                                devices: [DeviceInfo]) -> some View {
        if !devices.isEmpty {
            Section {
                ForEach(devices) { device in
                    Label {
                        HStack(spacing: 4) {
                            Text(device.name).lineLimit(1)
                            if device.isDefaultOutput || device.isDefaultInput {
                                Circle().fill(.green).frame(width: 6, height: 6)
                            }
                        }
                    } icon: {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                    }
                    .tag(device.id)
                }
            } header: {
                Text(title).font(.subheadline.weight(.semibold))
            }
        }
    }
}

// MARK: - Device detail panel

@available(macOS 13.0, *)
private struct DeviceDetailView: View {
    @EnvironmentObject var settings: AudioDeviceSettingsManager
    let device: DeviceInfo

    // Tab selection for I/O devices
    @State private var tab: Tab = .output

    enum Tab: String, CaseIterable {
        case input = "Input", output = "Output"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.title2.weight(.semibold))
                    Text(connectionType).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if device.isDefaultOutput || device.isDefaultInput {
                    Label("Default", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.green.opacity(0.15)))
                }
            }
            .padding()

            Divider()

            // Tab bar for I/O devices
            if device.hasInput && device.hasOutput {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let showInput  = device.hasInput  && (!device.hasOutput || tab == .input)
                    let showOutput = device.hasOutput && (!device.hasInput  || tab == .output)

                    if showOutput { outputControls }
                    if showInput  { inputControls  }

                    sampleRateControl

                    defaultDeviceButtons

                    Spacer(minLength: 0)
                }
                .padding()
            }
        }
        .onAppear {
            tab = device.hasOutput ? .output : .input
        }
    }

    // MARK: - Output controls

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Output volume
            ControlRow(label: "Output Volume", icon: "speaker.wave.2") {
                Slider(value: outputVolumeBinding, in: 0...1)
                Text("\(Int(device.outputVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!device.canSetOutputVolume)

            // Balance
            if device.canSetBalance {
                VStack(alignment: .leading, spacing: 4) {
                    ControlRow(label: "Balance", icon: "slider.horizontal.3") {
                        Slider(value: balanceBinding, in: 0...1)
                        Text(balanceLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(device.balance == 0.5 ? .green : .secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    HStack {
                        Spacer().frame(width: 160)
                        Text("L").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("R").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Input controls

    private var inputControls: some View {
        ControlRow(label: "Input Volume", icon: "mic") {
            Slider(value: inputVolumeBinding, in: 0...1)
            Text("\(Int(device.inputVolume * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .disabled(!device.canSetInputVolume)
    }

    // MARK: - Sample rate

    private var sampleRateControl: some View {
        ControlRow(label: "Sample Rate", icon: "waveform") {
            if device.availableSampleRates.isEmpty || !device.canSetSampleRate {
                Text(formatRate(device.sampleRate))
                    .font(.callout)
                    .foregroundStyle(device.canSetSampleRate ? .primary : .secondary)
            } else {
                Picker("", selection: sampleRateBinding) {
                    ForEach(device.availableSampleRates, id: \.self) { rate in
                        Text(formatRate(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
            }
        }
    }

    // MARK: - Default device buttons

    private var defaultDeviceButtons: some View {
        HStack(spacing: 10) {
            if device.hasOutput && !device.isDefaultOutput {
                Button("Set as Default Output") {
                    settings.setAsDefaultOutput(device.id)
                }
                .buttonStyle(.bordered)
            }
            if device.hasInput && !device.isDefaultInput {
                Button("Set as Default Input") {
                    settings.setAsDefaultInput(device.id)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private var connectionType: String {
        if device.hasInput && device.hasOutput { return "Input / Output" }
        if device.hasInput  { return "Input" }
        return "Output"
    }

    private var balanceLabel: String {
        if abs(device.balance - 0.5) < 0.02 { return "Centered" }
        let pct = Int((device.balance - 0.5) * 200)
        return pct < 0 ? "L \(abs(pct))%" : "R \(pct)%"
    }

    private func formatRate(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
        }
        return "\(Int(hz)) Hz"
    }

    // MARK: - Bindings

    private var outputVolumeBinding: Binding<Float> {
        Binding(get: { device.outputVolume },
                set: { settings.setOutputVolume($0, for: device.id) })
    }
    private var inputVolumeBinding: Binding<Float> {
        Binding(get: { device.inputVolume },
                set: { settings.setInputVolume($0, for: device.id) })
    }
    private var balanceBinding: Binding<Float> {
        Binding(get: { device.balance },
                set: { settings.setBalance($0, for: device.id) })
    }
    private var sampleRateBinding: Binding<Double> {
        Binding(get: { device.sampleRate },
                set: { settings.setSampleRate($0, for: device.id) })
    }
}

// MARK: - Reusable control row layout

private struct ControlRow<Content: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(label, systemImage: icon)
                .font(.callout)
                .frame(width: 140, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
