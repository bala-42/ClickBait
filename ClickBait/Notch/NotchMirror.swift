import AppKit
import AVFoundation
import ClickBaitCore
import SwiftUI

@MainActor
private final class CameraMirrorModel: ObservableObject {
    enum State {
        case starting
        case denied
        case unavailable
        case failed(String)
        case ready
    }

    /// One photo: a thumbnail, and its file in a temporary folder until it's saved.
    struct Shot: Identifiable {
        let id = UUID()
        let image: NSImage
        let file: URL
    }

    @Published private(set) var state: State = .starting
    /// Newest first, at most `maxShots`.
    @Published private(set) var shots: [Shot] = []
    static let maxShots = 4
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    /// Unsaved shots live here and go when the booth closes.
    private let scratch = FileManager.default.temporaryDirectory.appending(path: "ClickBait Mirror", directoryHint: .isDirectory)

    func start() {
        Task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureAndRun()
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { configureAndRun() } else { state = .denied }
            case .denied, .restricted:
                state = .denied
            @unknown default:
                state = .unavailable
            }
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        if case .ready = state { state = .starting }  // a countdown still running takes no photo
        shots = []
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Takes a photo, flipped to match the mirrored preview, and keeps it as the newest shot.
    func snap() async -> Bool {
        guard case .ready = state, let data = await PhotoGrab.take(from: photoOutput),
              let rep = NSBitmapImageRep(data: data), let source = rep.cgImage,
              let flipped = Self.mirrored(source),
              let jpeg = NSBitmapImageRep(cgImage: flipped).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return false }
        guard session.isRunning else { return false }  // closed while the photo was on its way
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let file = scratch.appending(path: "Mirror \(Self.stamp()).jpg")
            try jpeg.write(to: file)
            let image = NSImage(cgImage: flipped, size: NSSize(width: flipped.width, height: flipped.height))
            shots.insert(Shot(image: image, file: file), at: 0)
            for old in shots.dropFirst(Self.maxShots) { try? FileManager.default.removeItem(at: old.file) }
            shots = Array(shots.prefix(Self.maxShots))
            return true
        } catch {
            return false
        }
    }

    /// Copies every shot to ~/Pictures/ClickBait and shows them in Finder.
    func saveAll() {
        guard !shots.isEmpty,
              let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else { return }
        let folder = pictures.appending(path: "ClickBait", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = shots.compactMap { shot -> URL? in
            let target = folder.appending(path: shot.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { return target }
            return (try? FileManager.default.copyItem(at: shot.file, to: target)) != nil ? target : nil
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    private static func mirrored(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return format.string(from: Date())
    }

    private func configureAndRun() {
        guard !configured else {
            if !session.isRunning { session.startRunning() }
            state = .ready
            return
        }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            state = .unavailable
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                state = .failed("The camera could not be connected.")
                return
            }
            session.addInput(input)
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            session.commitConfiguration()
            configured = true
            session.startRunning()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// One `AVCapturePhotoOutput` capture as an async call: the photo's data, or nil on failure.
private final class PhotoGrab: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    // shortcut: one capture at a time per grab (the booth's countdown allows only one), guarded by the lock.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var data: Data?

    @MainActor static func take(from output: AVCapturePhotoOutput) async -> Data? {
        let grab = PhotoGrab()
        return await withCheckedContinuation { continuation in
            grab.lock.withLock { grab.continuation = continuation }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: grab)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.withLock { data = error == nil ? photo.fileDataRepresentation() : nil }
    }

    /// Always the last call, success or not.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        lock.withLock {
            continuation?.resume(returning: data)
            continuation = nil
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewHost {
        let view = CameraPreviewHost()
        view.wantsLayer = true
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        Self.mirror(view.previewLayer.connection)
        return view
    }

    func updateNSView(_ view: CameraPreviewHost, context: Context) {
        view.previewLayer.session = session
        Self.mirror(view.previewLayer.connection)
    }

    /// AVFoundation throws if mirroring is set while it still adjusts it automatically.
    private static func mirror(_ connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

private final class CameraPreviewHost: NSView {
    override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

/// The Mirror photo booth: the mirrored camera on the left; on the right the shutter (a 3-2-1
/// countdown, then a flash), the last four shots (drag one out, or save them all to
/// ~/Pictures/ClickBait) and the way back. Unsaved shots are deleted when it closes.
struct PhotoBooth: View {
    @StateObject private var camera = CameraMirrorModel()
    let tabBeans: Namespace.ID
    let onClose: () -> Void
    @State private var count: Int?
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                // The Mirror square's holo bean, flown up from Home.
                if let pill = IslandPills.pill(for: .mirror, music: nil) {
                    TabBean(pill: pill, size: 18)
                        .matchedGeometryEffect(id: NotchController.Model.Tab.mirror, in: tabBeans)
                        .accessibilityHidden(true)
                }
                Text("Mirror").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close mirror")
            }
            .foregroundStyle(NotchPalette.text)
            .padding(.horizontal, 16)
            .frame(height: 26)
            HStack(alignment: .top, spacing: 10) {
                viewfinder.frame(width: 420, height: 236)
                controls
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var viewfinder: some View {
        ZStack {
            Color(white: 0.06)
            switch camera.state {
            case .ready:
                CameraPreview(session: camera.session)
            case .starting:
                status("camera", "Starting camera…")
            case .denied:
                status("camera.badge.ellipsis", "Allow camera access in System Settings")
            case .unavailable:
                status("camera.metering.unknown", "No front camera available")
            case .failed(let message):
                status("exclamationmark.camera", message)
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 12)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("Photo in \(count)")
            }
            Color.white.opacity(flash ? 0.9 : 0).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var controls: some View {
        let ready = if case .ready = camera.state { true } else { false }
        return VStack(spacing: 10) {
            Button(action: shoot) {
                ZStack {
                    Circle().fill(.white).frame(width: 52, height: 52)
                    Circle().stroke(.white.opacity(0.5), lineWidth: 2).frame(width: 60, height: 60)
                    Image(systemName: "camera.fill").font(.system(size: 18)).foregroundStyle(Color.black)
                }
            }
            .buttonStyle(.plain)
            .disabled(!ready || count != nil)
            .opacity(ready && count == nil ? 1 : 0.4)
            .accessibilityLabel("Take a photo")
            LazyVGrid(columns: [GridItem(.fixed(84), spacing: 6), GridItem(.fixed(84), spacing: 6)], spacing: 6) {
                ForEach(0..<CameraMirrorModel.maxShots, id: \.self) { index in
                    shotTile(index < camera.shots.count ? camera.shots[index] : nil)
                }
            }
            Button("Save to Pictures") { camera.saveAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(camera.shots.isEmpty ? NotchPalette.secondary : NotchPalette.text)
                .padding(.horizontal, 12).frame(height: 24)
                .background(NotchPalette.ink, in: Capsule())
                .disabled(camera.shots.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func shotTile(_ shot: CameraMirrorModel.Shot?) -> some View {
        let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let shot {
            Image(nsImage: shot.image).resizable().scaledToFill()
                .frame(width: 84, height: 47).clipShape(tile)
                .onDrag { NSItemProvider(contentsOf: shot.file) ?? NSItemProvider() }
                .help("Drag the photo out")
                .accessibilityLabel("Photo, drag to save it somewhere")
        } else {
            tile.stroke(NotchPalette.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 84, height: 47)
                .accessibilityHidden(true)
        }
    }

    /// 3, 2, 1, flash, photo.
    private func shoot() {
        Task { @MainActor in
            for tick in [3, 2, 1] {
                withAnimation(reduceMotion ? nil : .snappy) { count = tick }
                try? await Task.sleep(for: .seconds(0.8))
            }
            count = nil
            flash = true
            _ = await camera.snap()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { flash = false }
        }
    }

    private func status(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
            Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}
