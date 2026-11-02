import Foundation

/// ⌥⇥ window switching (user's ask, 2026-11-02, after AltTab): which windows count, and the
/// selection moving through them. Pure: the app lists, draws and brings forward.
public enum WindowSwitch {
    public struct Window: Equatable, Sendable {
        public let id: UInt32
        public let pid: Int32
        public let layer: Int
        public let width: Double
        public let height: Double
        public let title: String
        public init(id: UInt32, pid: Int32, layer: Int, width: Double, height: Double, title: String) {
            (self.id, self.pid, self.layer, self.width, self.height, self.title) = (id, pid, layer, width, height, title)
        }
    }

    /// Ordinary windows (layer 0, not tiny, not ClickBait's own), front to back as given.
    public static func eligible(_ windows: [Window], own: Int32) -> [Window] {
        windows.filter { $0.layer == 0 && $0.pid != own && $0.width >= 80 && $0.height >= 60 }
    }

    /// Where the selection starts: the window behind the front one (⇧: the last), as ⌘⇥ does.
    public static func first(count: Int, backwards: Bool) -> Int {
        guard count > 1 else { return 0 }
        return backwards ? count - 1 : 1
    }

    /// One step on, round the ends.
    public static func step(_ index: Int, count: Int, backwards: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (index + (backwards ? -1 : 1) + count) % count
    }
}
