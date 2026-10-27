import AppKit
import ClickBaitCore
import SwiftUI
import Testing
@testable import ClickBait

/// Every setup step drawn as the window draws it (520×480), to look at: the PNGs go to the
/// temporary folder (ClickBaitTests-setup). States are this Mac's own.
@MainActor
struct SetupRenderTests {
    @Test func everyStepDraws() throws {
        let settings = AppSettings()
        let permissions = PermissionsManager()
        let speech = SpeechModelManager(settings: settings)
        let model = ModelSetupChecker(settings: settings)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClickBaitTests-setup")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, step) in OnboardingStep.allCases.enumerated() {
            let view = OnboardingView(permissions: permissions, settings: settings, speech: speech, model: model, startAt: step, onDone: {})
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.frame = CGRect(x: 0, y: 0, width: 520, height: 480)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.sharpRep())
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(index + 1)-\(step).png"))
        }
    }
}
