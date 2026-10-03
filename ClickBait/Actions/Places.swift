import AppKit
import ClickBaitCore

/// Where named places are on this Mac, and the place-level actions.
enum Places {
    static func url(for place: Place) throws -> URL {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let url: URL? = switch place {
        case .desktop: manager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .downloads: manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .documents: manager.urls(for: .documentDirectory, in: .userDomainMask).first
        case .home: home
        case .applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .iCloudDrive: home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        case .pictures: manager.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .music: manager.urls(for: .musicDirectory, in: .userDomainMask).first
        case .movies: manager.urls(for: .moviesDirectory, in: .userDomainMask).first
        }
        guard let url, manager.fileExists(atPath: url.path) else {
            throw FileActionError.unsupported("\(place.displayName.prefix(1).uppercased() + place.displayName.dropFirst()) isn't set up on this Mac.")
        }
        return url
    }

    /// An empty folder in `place`, or in the front Finder window's folder (Desktop if
    /// there's none), named as asked or "untitled folder", then selected in Finder.
    @MainActor
    static func newFolder(in place: Place?, name: String?) async throws -> String {
        let parent: URL
        let whereName: String
        if let place {
            parent = try url(for: place)
            whereName = place.displayName
        } else if let front = await FinderSelection.frontFolder() {
            parent = front
            whereName = front.lastPathComponent
        } else {
            parent = try url(for: .desktop)
            whereName = Place.desktop.displayName
        }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
        let folderName = OutputName.unique(base: name ?? "untitled folder", extension: "", existing: existing)
        let folder = parent.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        return "Made “\(folderName)” in \(whereName)"
    }

    @MainActor
    static func open(_ place: Place) throws -> String {
        NSWorkspace.shared.open(try url(for: place))
        return "Opened \(place.displayName)"
    }
}
