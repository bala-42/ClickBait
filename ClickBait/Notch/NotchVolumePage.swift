import ClickBaitCore
import CoreAudio
import SwiftUI

/// The Volume page behind the bottom-right bubble (user's references: Vorssaint's mixer): the
/// output, a main slider, and one per app playing sound (↺ back to 100%, boost to 150% in the
/// teleprompter's cream); its settings: output, system sounds, microphone and its level.
struct NotchVolumePage: View {
    @Bindable var mixer = AppVolumeMixer.shared
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                deviceMenu(mixer.outputs, chosen: mixer.output) { mixer.choose(output: $0) }
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button { showsSettings.toggle() } label: {
                    Image(systemName: showsSettings ? "xmark" : "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 22)
                        .background(Color.white.opacity(showsSettings ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchPalette.secondary)
                .accessibilityLabel(showsSettings ? "Close sound settings" : "Sound settings")
            }
            if showsSettings { settings } else { sliders }
            if let problem = mixer.problem {
                Text(problem).font(.system(size: 10)).foregroundStyle(CompanionTone.problem).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .task {
            while !Task.isCancelled {
                mixer.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var sliders: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)).frame(height: 24)
                VolumeBar(value: mixer.mainVolume, maximum: 1) { mixer.setMainVolume($0) }
                Text("\(Int((mixer.mainVolume * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(NotchPalette.secondary)
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).padding(.vertical, 4)
            if mixer.apps.isEmpty {
                Text("Apps playing sound show up here.").font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(mixer.apps) { app in appColumn(app) }
                    }
                }
            }
        }
        .foregroundStyle(NotchPalette.text)
        .frame(height: 170)
    }

    private func appColumn(_ app: SystemAudio.PlayingApp) -> some View {
        let level = mixer.volume(of: app)
        return VStack(spacing: 6) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app.fill").resizable() }
            }
            .frame(width: 24, height: 24)
            .help(app.name)
            VolumeBar(value: level, maximum: AppVolumeMixer.maximum) { mixer.setVolume($0, for: app) }
            HStack(spacing: 4) {
                if abs(level - 1) > 0.01 {
                    Button { mixer.reset(app) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).accessibilityLabel("\(app.name) back to 100%")
                }
                Text("\(level > 1.01 ? "⚡︎" : "")\(Int((level * 100).rounded()))%").monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(level > 1.01 ? MoodyLook.cream : NotchPalette.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow("Output", "speaker.wave.2") { deviceMenu(mixer.outputs, chosen: mixer.output) { mixer.choose(output: $0) } }
            settingRow("System sounds", "bell") { deviceMenu(mixer.outputs, chosen: mixer.systemOutput) { mixer.choose(systemOutput: $0) } }
            settingRow("Microphone", "mic") { deviceMenu(mixer.inputs, chosen: mixer.input) { mixer.choose(input: $0) } }
            if let level = mixer.inputVolume {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    Slider(value: Binding(get: { level }, set: { mixer.setInputVolume($0) }), in: 0...1).controlSize(.small).tint(NotchPalette.text)
                    Text("\(Int((level * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(NotchPalette.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(NotchPalette.text)
        .frame(height: 170, alignment: .top)
    }

    private func settingRow<Picker: View>(_ title: String, _ symbol: String, @ViewBuilder picker: () -> Picker) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(NotchPalette.secondary)
            Spacer()
            picker().font(.system(size: 11))
        }
    }

    private func deviceMenu(_ devices: [SystemAudio.Device], chosen: AudioObjectID?, choose: @escaping (AudioObjectID) -> Void) -> some View {
        Menu(devices.first { $0.id == chosen }?.name ?? "—") {
            ForEach(devices) { device in
                Button(device.name) { choose(device.id) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A tall rounded slider, dragged up and down; past 100% (a boost) it fills in cream.
private struct VolumeBar: View {
    let value: Double
    let maximum: Double
    let set: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let full = min(value, 1) / maximum, boost = max(0, value - 1) / maximum
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12))
                VStack(spacing: 0) {
                    Rectangle().fill(MoodyLook.cream).frame(height: height * boost)
                    Rectangle().fill(NotchPalette.text).frame(height: height * full)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if maximum > 1 {
                    // Where 100% is.
                    Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1).offset(y: -height / maximum)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let level = (1 - drag.location.y / height) * maximum
                // A little stick at 100%, so it's easy to land back on it.
                set(abs(level - 1) < 0.04 && maximum > 1 ? 1 : min(maximum, max(0, level)))
            })
        }
        .frame(width: 30, height: 112)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in set(min(maximum, max(0, value + (direction == .increment ? 0.05 : -0.05)))) }
    }
}
