import AppKit
import SwiftUI
import Testing
@testable import ClickBait

/// The notch header's Internet Mode switch, both ways, to look at (ClickBaitTests-notch).
@MainActor
struct InternetSwitchRenderTests {
    @Test func bothStatesDraw() throws {
        let local = InternetMode(), online = InternetMode()
        online.toggle()
        let row = HStack(spacing: 14) {
            InternetSwitch(internet: local)
            InternetSwitch(internet: online)
            Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(NotchPalette.secondary)
            Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(NotchPalette.secondary)
            Image(systemName: "xmark").font(.system(size: 14)).foregroundStyle(NotchPalette.secondary)
        }
        .padding(16).background(Color.black)
        let host = NSHostingView(rootView: row)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-notch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "internet-switch.png"))
        #expect(online.isOn && !local.isOn)
    }
}
