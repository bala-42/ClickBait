import AppKit
import ClickBaitCore
import SwiftUI

/// The gallery behind the top-left bubble (user's ask, 2026-11-02, after Vorssaint's): tiles in
/// rows of five, each opening its own page in the notch with ‹ back. Only what the four mini
/// bean buttons don't already open (Lookup, Shelf, Studio, the player) and not the timer (its
/// own bubble). Pages join as they're built.
enum GalleryPage: String, CaseIterable, Identifiable {
    case controls

    var id: String { rawValue }
    var title: String {
        switch self {
        case .controls: "Controls"
        }
    }
    var symbol: String {
        switch self {
        case .controls: "slider.horizontal.3"
        }
    }
    /// The notch's size on this page.
    var size: (width: Double, height: Double) {
        switch self {
        case .controls: (640, 200)
        }
    }
}

struct GalleryView: View {
    let model: NotchController.Model
    @Bindable var settings: AppSettings

    var body: some View {
        if let page = model.galleryPage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.openGallery(nil) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NotchPalette.secondary)
                    .accessibilityLabel("Back to the gallery")
                    Text(page.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchPalette.text)
                    Spacer()
                }
                switch page {
                case .controls: ControlsPage(settings: settings)
                }
            }
            .padding(.horizontal, 6)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(GalleryPage.allCases) { page in
                    Button { model.openGallery(page) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: page.symbol).font(.system(size: 18, weight: .regular))
                            Text(page.title).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(NotchPalette.text)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlayerPressStyle())
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

/// Quick switches (after Vorssaint's Controls, with ClickBait's own): tap to flip; on is lit.
private struct ControlsPage: View {
    @Bindable var settings: AppSettings
    @State private var dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

    var body: some View {
        HStack(spacing: 8) {
            toggle("Vision Memory", "eye", on: settings.visionDescribe && !(settings.visionPausedUntil.map { $0 > Date() } ?? false)) {
                if settings.visionPausedUntil.map({ $0 > Date() }) ?? false { settings.visionPausedUntil = nil } else { settings.visionPausedUntil = .distantFuture }
            }
            toggle("Voice answers", "speaker.wave.2", on: settings.speakAnswers) { settings.speakAnswers.toggle() }
            toggle("Internet Mode", "globe", on: settings.internet.isOn) { settings.internet.toggle() }
            toggle("Work on battery", "battery.75percent", on: settings.visionOnBattery) { settings.visionOnBattery.toggle() }
            toggle("Dark mode", "moon", on: dark) {
                dark.toggle()
                let want = dark
                Task { _ = try? await ActionExecutor.run(.setDarkMode(want)) }
            }
        }
    }

    private func toggle(_ name: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? NotchPalette.ink : NotchPalette.text)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? NotchPalette.text : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(name)
        .accessibilityValue(on ? "on" : "off")
    }
}
