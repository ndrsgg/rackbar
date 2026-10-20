import AppKit
import Observation
import RackbarCore

/// The one folder Rackbar may write to, granted by the user in an open panel
/// and remembered as a security-scoped bookmark.
///
/// In the App Sandbox this is the whole of Rackbar's reach into `~/.ssh`. It
/// never sees the keys or the user's own config; ssh reads its file through
/// the `Include` line the user adds.
@MainActor
@Observable
final class SSHFolder {
    private(set) var url: URL?
    private(set) var problem: String?

    private let defaultsKey = "sshFolderBookmark"

    init() {
        restore()
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Rackbar"
        panel.message = """
            Create a new folder inside .ssh — “hcloud”, for example — and choose it. \
            Rackbar can only see this one folder: not your keys, not your own ssh config.
            """
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = RealHome.sshDirectory
        NSApp.activate()
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            try accept(chosen)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        url = nil
        problem = nil
    }

    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        guard let url else { throw FolderError.noFolder }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private func accept(_ chosen: URL) throws {
        let path = chosen.standardizedFileURL.path
        if path == RealHome.sshDirectory.standardizedFileURL.path || path == RealHome.url.standardizedFileURL.path {
            throw FolderError.tooBroad
        }
        let started = chosen.startAccessingSecurityScopedResource()
        defer { if started { chosen.stopAccessingSecurityScopedResource() } }
        // A folder that holds anything but Rackbar's own file belongs to
        // someone else, and a grant to it would reach further than needed.
        let foreign = try FileManager.default.contentsOfDirectory(atPath: chosen.path).filter {
            $0 != SSHConfigFile.fileName && $0 != ".DS_Store" && !$0.hasPrefix(".config.rackbar-")
        }
        guard foreign.isEmpty else { throw FolderError.notEmpty(foreign.sorted()) }
        try saveBookmark(for: chosen)
        url = chosen
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale {
                let started = resolved.startAccessingSecurityScopedResource()
                defer { if started { resolved.stopAccessingSecurityScopedResource() } }
                try saveBookmark(for: resolved)
            }
            url = resolved
        } catch {
            problem = "Rackbar lost access to its folder. Choose it again."
        }
    }

    private func saveBookmark(for folder: URL) throws {
        let data = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                           relativeTo: nil)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum FolderError: LocalizedError {
    case noFolder
    case tooBroad
    case notEmpty([String])

    var errorDescription: String? {
        switch self {
        case .noFolder:
            "No folder chosen yet."
        case .tooBroad:
            "Choose a folder of its own inside .ssh, not .ssh itself — that would show Rackbar your keys."
        case .notEmpty(let names):
            "That folder already holds \(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? " …" : ""). "
                + "Create an empty folder for Rackbar instead."
        }
    }
}
