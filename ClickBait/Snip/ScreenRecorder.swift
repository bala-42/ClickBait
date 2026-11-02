import AppKit
import ClickBaitCore
import OSLog
import ScreenCaptureKit
import SwiftUI

/// Screen recording, from the Quick panel's Capture (user's ask, 2026-11-02, after Vorssaint's):
/// the screen the pointer is on, with the sound the Mac plays (not the microphone), ClickBait's
/// own windows and blocked apps left out — ScreenCaptureKit writing straight to a movie in
/// Movies. A red "● 0:12 · stop" pill at the bottom of that screen (not in the recording) stops it.
@MainActor @Observable
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate {
    static let shared = ScreenRecorder()
    private(set) var startedAt: Date?
    var recording: Bool { startedAt != nil }
    @ObservationIgnored var onSaved: (URL) -> Void = { _ in }
    @ObservationIgnored var onProblem: (String) -> Void = { _ in }
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var pill: NSPanel?

    func start(blocklist: AppBlocklist) async {
        guard !recording else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == number }) ?? content.displays.first else {
                return onProblem("couldn't find the screen to record")
            }
            let own = ProcessInfo.processInfo.processIdentifier
            let left = content.applications.filter { $0.processID == own || blocklist.isBlocked(bundleID: $0.bundleIdentifier) }
            let filter = SCContentFilter(display: display, excludingApplications: left, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            configuration.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = true
            configuration.capturesAudio = true
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            let file = folder.appending(path: "ClickBait Recording \(formatter.string(from: Date())).mov")
            let settings = SCRecordingOutputConfiguration()
            settings.outputURL = file
            settings.outputFileType = .mov
            let output = SCRecordingOutput(configuration: settings, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            (self.stream, self.output, self.file, startedAt) = (stream, output, file, Date())
            showPill(on: screen)
            Log.app.notice("Recording started")
        } catch {
            onProblem("couldn't record: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        startedAt = nil
        pill?.orderOut(nil)
        pill = nil
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let file else { return }
            self.file = nil
            output = nil
            Log.app.notice("Recording saved")
            onSaved(file)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            await stop()
            onProblem("the recording stopped: \(error.localizedDescription)")
        }
    }

    private func showPill(on screen: NSScreen) {
        let host = NSHostingView(rootView: RecordingPill(recorder: self))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24))
        panel.orderFrontRegardless()
        pill = panel
    }
}

/// "● 0:12 · stop", in the problem pills' red, as macOS's own recording dot.
private struct RecordingPill: View {
    let recorder: ScreenRecorder

    var body: some View {
        Button { Task { await recorder.stop() } } label: {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AgentLive.clock(context.date.timeIntervalSince(recorder.startedAt ?? context.date))).monospacedDigit()
                }
                Text("· stop").foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Stop recording")
    }
}
