import SwiftUI
import ServiceManagement
import HelioCore

struct SettingsView: View {
    let model: AppModel

    @AppStorage("age") private var age = 30
    @AppStorage("alertEnabled") private var alertEnabled = false
    @AppStorage("alertThreshold") private var alertThreshold = 100
    @AppStorage("alertDurationMin") private var alertDurationMin = 3
    @AppStorage("batteryAlertEnabled") private var batteryAlertEnabled = true
    @AppStorage("batteryAlertThreshold") private var batteryAlertThreshold = 20
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Stepper("Age: \(age)", value: $age, in: 10...100)
                Text("Max HR ≈ \(220 - age) bpm · zones scale to this")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("You", systemImage: "person.fill")
            }
            deviceSection
            Section {
                Toggle("Notify when HR stays high", isOn: $alertEnabled)
                Stepper("Above \(alertThreshold) bpm", value: $alertThreshold, in: 80...200, step: 5)
                Stepper("For \(alertDurationMin) min", value: $alertDurationMin, in: 1...30)
            } header: {
                Label("Elevated-HR alert", systemImage: "heart.text.square.fill")
            }
            Section {
                Toggle("Notify when strap battery is low", isOn: $batteryAlertEnabled)
                Stepper("At or below \(batteryAlertThreshold)%", value: $batteryAlertThreshold, in: 5...50, step: 5)
            } header: {
                Label("Strap battery alert", systemImage: "battery.25percent")
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunch(on) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Label("System", systemImage: "power")
            }
        }
        .formStyle(.grouped)
        .frame(width: 330, height: 480)
        .onAppear { model.rescanDevices() }
        .onDisappear { model.stopDeviceScan() }
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if let connected = model.store.connectedDevice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(connected.name)
                    Spacer()
                    Text("Connected").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.store.discoveredDevices) { dev in
                Button {
                    model.selectDevice(dev.id)
                } label: {
                    HStack(spacing: 8) {
                        SignalBars(level: dev.signalBars)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dev.name)
                            Text("…\(dev.idSuffix)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if dev.id == model.store.connectedDevice?.id {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if model.store.discoveredDevices.isEmpty {
                Text("Searching for straps…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Forget / auto-pick", role: .destructive) { model.forgetDevice() }
        } header: {
            Label("Device", systemImage: "dot.radiowaves.left.and.right")
        } footer: {
            Text("HelioBar remembers this strap and reconnects only to it. Signal bars and the ID suffix help tell identical straps apart.")
                .font(.caption2)
        }
    }

    private func setLaunch(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            launchAtLoginError = error.localizedDescription
        }
    }
}
