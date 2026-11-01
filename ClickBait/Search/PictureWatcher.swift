import CoreServices
import Foundation

/// Watches Vision Memory's folders (FSEvents): a picture added, renamed or deleted updates the
/// index within seconds (a quick pass: pictures only), instead of at the next 30-minute pass.
@MainActor
final class PictureWatcher {
    static let shared = PictureWatcher()
    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?

    /// (Re)starts watching `folders`; `onChange` runs on the main thread, at most every 5 s.
    func watch(_ folders: [String], onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PictureWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange?() } }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
