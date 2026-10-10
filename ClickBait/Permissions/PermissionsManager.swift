import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Observation

enum PermissionKind: CaseIterable, Identifiable {
    case microphone
    case screenRecording
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .microphone:
            "Lets ClickBait hear your question while you hold Control+Option."
        case .screenRecording:
            "Lets ClickBait see the screen you're asking about. Screenshots never leave your Mac."
        case .accessibility:
            "Lets ClickBait notice the hotkey in any app and aim the pointer at real buttons."
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: "mic.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }

    var settingsURL: URL? {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum PermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
}

/// Tracks Microphone, Screen Recording and Accessibility access. macOS sends no
/// notifications for these, so status is polled while someone is watching.
@MainActor
@Observable
final class PermissionsManager {
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        refresh()
    }

    var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { status(of: $0) == .granted }
    }

    func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }

    func refresh() {
        var updated: [PermissionKind: PermissionStatus] = [:]
        for kind in PermissionKind.allCases {
            updated[kind] = Self.currentStatus(of: kind)
        }
        if updated != statuses {
            statuses = updated
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Shows the system prompt where macOS still allows one; otherwise opens the
    /// matching System Settings pane.
    func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            if status(of: .microphone) == .notDetermined {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    refresh()
                }
            } else {
                openSettings(for: kind)
            }
        case .screenRecording:
            // Shows the prompt once and adds ClickBait to the list; later calls do nothing.
            if !CGRequestScreenCaptureAccess() {
                openSettings(for: kind)
            }
        case .accessibility:
            // The key is spelled out because the kAXTrustedCheckOptionPrompt global
            // isn't concurrency-safe under Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) {
                openSettings(for: kind)
            }
        }
        refresh()
    }

    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private static func currentStatus(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        }
    }
}
