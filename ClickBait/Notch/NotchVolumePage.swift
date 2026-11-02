import ClickBaitCore
import CoreAudio
import SwiftUI

/// The Volume page behind the bottom-right bubble (user's references: Vorssaint's notch mixer): the
/// output, a main slider, and a column per app using sound — a green dot while it plays, ⋯ for
/// its own output, ↺ back to 100%, boost to 150% in the teleprompter's cream, 🔈 to mute — in a
/// row that scrolls sideways; its settings: output, system sounds, microphone and its level.
struct NotchVolumePage: View {
    @Bindable var mixer = AppVolumeMixer.shared
    /// Off in renders (ImageRenderer can't draw the sliders' AppKit input).
    var interactive = true
    @State private var showsSettings = false
    /// Each muted app's level before, to come back to.
    @State private var unmuted: [String: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume mixer").font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchPalette.text)
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
        .padding(.horizontal, 12)
        .task {
            while !Task.isCancelled {
                mixer.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var sliders: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)).frame(height: 24)
                VolumeBar(value: mixer.mainVolume, maximum: 1, interactive: interactive) { mixer.setMainVolume($0) }
                Text("\(Int((mixer.mainVolume * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(NotchPalette.secondary)
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).padding(.vertical, 4)
            if mixer.apps.isEmpty {
                Text("Apps using sound show up here.").font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 20) {
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
        let own = mixer.output(of: app)
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                if mixer.pinned.contains(app.bundleID) {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(NotchPalette.tertiary).accessibilityLabel("Pinned")
                }
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app.fill").resizable() }
                }
                .frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    // Playing now.
                    if app.playing {
                        Circle().fill(CompanionTone.action.color).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5)).offset(x: 2, y: 2)
                    }
                }
                .help(app.name)
                // Its own output (per app: music on the speakers while a call uses the headset).
                Menu {
                    Button { mixer.setOutput(nil, for: app) } label: { Label("Mac's output", systemImage: own == nil ? "checkmark" : "") }
                    ForEach(mixer.outputs) { device in
                        Button { mixer.setOutput(device.uid, for: app) } label: { Label(device.name, systemImage: own == device.uid ? "checkmark" : "") }
                    }
                    Divider()
                    Button(mixer.pinned.contains(app.bundleID) ? "Unpin" : "Pin first") { mixer.togglePin(app) }
                    if abs(level - 1) > 0.01 || own != nil {
                        Divider()
                        Button("Back to normal") { mixer.setOutput(nil, for: app); mixer.reset(app) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(own == nil ? NotchPalette.secondary : MoodyLook.cream)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(own.flatMap { uid in mixer.outputs.first { $0.uid == uid }?.name }.map { "Plays to \($0)" } ?? "Output for \(app.name)")
            }
            VolumeBar(value: level, maximum: AppVolumeMixer.maximum, interactive: interactive) { mixer.setVolume($0, for: app) }
            HStack(spacing: 4) {
                if abs(level - 1) > 0.01 {
                    Button { mixer.reset(app) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).accessibilityLabel("\(app.name) back to 100%")
                }
                Text("\(level > 1.01 ? "⚡︎" : "")\(Int((level * 100).rounded()))%").monospacedDigit()
                Button {
                    if level == 0 {
                        mixer.setVolume(unmuted[app.bundleID] ?? 1, for: app)
                    } else {
                        unmuted[app.bundleID] = level
                        mixer.setVolume(0, for: app)
                    }
                } label: { Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.1") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(level == 0 ? "Unmute \(app.name)" : "Mute \(app.name)")
            }
            .font(.system(size: 11))
            .foregroundStyle(level > 1.01 ? MoodyLook.cream : NotchPalette.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow("Output", "speaker.wave.2") { deviceMenu(mixer.outputs, chosen: mixer.output) { mixer.choose(output: $0) } }
            settingRow("System sounds", "bell") { deviceMenu(mixer.outputs, chosen: mixer.systemOutput) { mixer.choose(systemOutput: $0) } }
            settingRow("Microphone", "mic") { deviceMenu(mixer.inputs, chosen: mixer.input) { mixer.choose(input: $0) } }
            Toggle(isOn: $mixer.lowerWhenHeadphonesOut) {
                Label("Turn down when headphones come out", systemImage: "headphones").foregroundStyle(NotchPalette.secondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
            if let level = mixer.inputVolume {
                HStack(spacing: 12) {
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
    var interactive = true
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
            .overlay {
                if interactive {
                    BarInput(value: value, maximum: maximum, set: set)
                }
            }
        }
        .frame(width: 30, height: 112)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in set(min(maximum, max(0, value + (direction == .increment ? 0.05 : -0.05)))) }
    }
}

/// The bar's mouse and scrolling (user's ask, 2026-11-02, "finer steps"): click or drag to a
/// level (a little stick at 100%); ⌥-drag moves a quarter as fast; scrolling up or down steps
/// 1% at a time; sideways scrolling goes on to the row, which scrolls.
private struct BarInput: NSViewRepresentable {
    let value: Double
    let maximum: Double
    let set: (Double) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { (view.value, view.maximum, view.set) = (value, maximum, set) }

    final class InputView: NSView {
        var value = 0.0, maximum = 1.0
        var set: (Double) -> Void = { _ in }
        private var pending: CGFloat = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { if !event.modifierFlags.contains(.option) { jump(event) } }
        override func mouseDragged(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                put(value - Double(event.deltaY / bounds.height) * maximum / 4)
            } else {
                jump(event)
            }
        }
        override func scrollWheel(with event: NSEvent) {
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return super.scrollWheel(with: event) }
            pending += event.scrollingDeltaY
            while abs(pending) >= 4 {
                put(value + (pending > 0 ? 0.01 : -0.01))
                pending -= pending > 0 ? 4 : -4
            }
        }
        private func jump(_ event: NSEvent) {
            let level = Double(convert(event.locationInWindow, from: nil).y / bounds.height) * maximum
            put(abs(level - 1) < 0.04 && maximum > 1 ? 1 : level)
        }
        private func put(_ level: Double) {
            value = min(maximum, max(0, (level * 100).rounded() / 100))
            set(value)
        }
    }
}
