import AppKit
import ClickBaitCore
import SwiftUI

/// The gallery behind the top-left bubble (user's ask, 2026-11-02, after Vorssaint's): tiles in
/// rows of five, each opening its own page in the notch with ‹ back. Only what the four mini
/// bean buttons don't already open (Lookup, Shelf, Studio, the player) and not the timer (its
/// own bubble). Pages join as they're built.
enum GalleryPage: String, CaseIterable, Identifiable {
    // What nothing else in ClickBait does (user's calls, 2026-11-02: the rest repeated the ⚙
    // bubble, the dock, Home's note, the shortcuts and the shelf).
    case agents, tools, clipboard, capture, health, colour

    /// Acts on a tap instead of opening a page.
    var acts: Bool { self == .colour }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: "AI Agents"
        case .tools: "Tools"
        case .capture: "Capture"
        case .colour: "Colour"
        case .health: "Health"
        case .clipboard: "Clipboard"
        }
    }
    var symbol: String {
        switch self {
        case .agents: "sparkles"
        case .tools: "wrench.and.screwdriver"
        case .capture: "camera.viewfinder"
        case .colour: "eyedropper"
        case .health: "heart.text.square"
        case .clipboard: "doc.on.clipboard"
        }
    }
    /// The notch's size on the tiles: two rows of 72, 8 between, under the 36 header, inside
    /// the open notch's 8 top and 12 bottom.
    static let gridSize: (width: Double, height: Double) = (448, 8 + 36 + 2 * 72 + 8 + 12)
    /// The notch's size on this page.
    var size: (width: Double, height: Double) {
        switch self {
        case .agents: (640, 440)
        case .clipboard: (640, 260)
        case .tools: (640, 240)
        case .health: (640, 420)
        case .capture: (640, 200)
        case .colour: GalleryPage.gridSize
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
                case .agents: NotchAgentsPage()
                case .tools: ToolsPage()
                case .clipboard: ClipboardPage()
                case .health: HealthPage()
                case .capture: CapturePage()
                case .colour: EmptyView()  // acts on a tap
                }
            }
            .padding(.horizontal, 8)
        } else {
            // The tiles, two rows of three (user's asks, 2026-11-02); the notch fits them (`gridSize`).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(GalleryPage.allCases) { page in
                    Button { page.acts ? GalleryHooks.capture(.colour) : model.openGallery(page) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: page.symbol).font(.system(size: 18, weight: .regular)).frame(height: 24)
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
            .padding(.horizontal, 8)
        }
    }
}
