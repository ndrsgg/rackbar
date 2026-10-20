import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SSHHost: Hashable, Sendable {
    public var alias: String
    public var hostName: String

    public init(alias: String, hostName: String) {
        self.alias = alias
        self.hostName = hostName
    }
}

public enum SSHConfigError: Error, Equatable, Sendable, LocalizedError {
    case invalidAlias(String)
    case invalidAddress(alias: String, address: String)
    case invalidUser(String)
    case invalidIdentityFile(String)
    case existingFileTooLarge
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAlias(let alias):
            "Refusing to write \(alias.debugDescription) as an ssh Host."
        case .invalidAddress(let alias, let address):
            "Refusing to write \(address.debugDescription) as the HostName for \(alias)."
        case .invalidUser(let user):
            "The ssh user \(user.debugDescription) has whitespace or control characters in it."
        case .invalidIdentityFile(let path):
            "The identity file \(path.debugDescription) has whitespace or control characters in it."
        case .existingFileTooLarge:
            "The existing ssh config file is larger than Rackbar would ever write."
        case .writeFailed(let reason):
            "Could not write the ssh config: \(reason)"
        }
    }
}

/// The file Rackbar owns, in a folder the user granted it, and pulled into
/// `~/.ssh/config` by one `Include` line the user adds themselves.
///
/// Rackbar never sees `~/.ssh/config` or a key. The file it writes is read by
/// ssh, though, and a stray newline in a server name would smuggle in a
/// `ProxyCommand` — so nothing is written unless every field passes, and a
/// bad one refuses the whole job rather than silently dropping a host.
public enum SSHConfigFile {
    public static let fileName = "config"

    public static func render(hosts: [SSHHost], user: String, identityFile: String) throws(SSHConfigError) -> String {
        guard isPlainValue(user) else { throw .invalidUser(user) }
        guard isPlainValue(identityFile) else { throw .invalidIdentityFile(identityFile) }
        for host in hosts {
            guard isValidAlias(host.alias) else { throw .invalidAlias(host.alias) }
            guard isIPAddress(host.hostName) else {
                throw .invalidAddress(alias: host.alias, address: host.hostName)
            }
        }

        // Sorted and free of timestamps, so an unchanged fleet renders to the
        // same bytes and the file is not rewritten every refresh.
        var lines = [
            "# Written by Rackbar (https://rackbar.app) for your Hetzner Cloud servers.",
            "# Rackbar owns this file and rewrites it on every sync; edits here are lost.",
            "# Put your own settings in ~/.ssh/config, above the line that includes this.",
        ]
        for host in hosts.sorted(by: { $0.alias < $1.alias }) {
            lines.append("")
            lines.append("Host \(host.alias)")
            lines.append("    HostName \(host.hostName)")
            if !user.isEmpty { lines.append("    User \(user)") }
            if !identityFile.isEmpty { lines.append("    IdentityFile \(identityFile)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The lines that go at the end of `~/.ssh/config`. At the end, so the
    /// user's own `Host` blocks above win: ssh takes the first value it finds.
    /// `Match all` ends whatever `Host` block came last, or the `Include`
    /// would only apply inside it.
    public static func includeDirective(folder: URL, home: URL = RealHome.url) -> String {
        "Match all\nInclude \(includePath(folder: folder, home: home))"
    }

    /// A command that appends the directive, for pasting into a terminal. It
    /// starts with a newline, because a config that does not end in one
    /// would otherwise glue `Match all` onto its last line.
    public static func appendCommand(folder: URL, home: URL = RealHome.url) -> String {
        let format = "\\n" + includeDirective(folder: folder, home: home)
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "\n", with: "\\n") + "\\n"
        let quoted = "'" + format.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "printf \(quoted) >> ~/.ssh/config"
    }

    /// The `Include` argument: relative inside `~/.ssh`, where ssh resolves it
    /// from, `~/…` elsewhere in the home folder, absolute otherwise.
    public static func includePath(folder: URL, home: URL = RealHome.url) -> String {
        let file = folder.standardizedFileURL.appendingPathComponent(fileName).path
        let sshDirectory = home.standardizedFileURL.appendingPathComponent(".ssh").path + "/"
        let homeDirectory = home.standardizedFileURL.path + "/"
        let path: String
        if file.hasPrefix(sshDirectory) {
            path = String(file.dropFirst(sshDirectory.count))
        } else if file.hasPrefix(homeDirectory) {
            path = "~/" + file.dropFirst(homeDirectory.count)
        } else {
            path = file
        }
        return path.contains(" ") ? "\"\(path)\"" : path
    }

    /// `[A-Za-z0-9][A-Za-z0-9._/-]*`
    static func isValidAlias(_ alias: String) -> Bool {
        guard let first = alias.unicodeScalars.first, first != "." && first != "_" && first != "/" && first != "-"
        else { return false }
        return alias.unicodeScalars.allSatisfy(isAliasScalar)
    }

    /// Empty, or one word without anything ssh would read as a break.
    static func isPlainValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\""
        }
    }

    static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

/// Writes `config` into the granted folder: atomically, mode 600, and not at
/// all when nothing changed.
public struct SSHConfigWriter: Sendable {
    public enum Outcome: Equatable, Sendable {
        case written
        case unchanged
    }

    /// Far beyond any fleet; a larger file is not one Rackbar wrote.
    static let maxExisting = 1024 * 1024

    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var fileURL: URL { folder.appendingPathComponent(SSHConfigFile.fileName) }

    public func write(_ contents: String) throws(SSHConfigError) -> Outcome {
        let data = Data(contents.utf8)
        if let existing = try readExisting(), existing == data {
            return .unchanged
        }
        // A temporary file beside the target and a rename over it: a crash
        // leaves the old file or the new one, never half of either.
        let temporary = folder.appendingPathComponent(".config.rackbar-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw .writeFailed("cannot create a file in \(folder.path)")
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw .writeFailed(reason)
        }
        return .written
    }

    private func readExisting() throws(SSHConfigError) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Self.maxExisting + 1)) ?? nil
        if let data, data.count > Self.maxExisting { throw .existingFileTooLarge }
        return data ?? Data()
    }
}

/// The user's home folder, not the sandbox container `NSHomeDirectory()`
/// answers with inside the App Sandbox.
public enum RealHome {
    public static var url: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var sshDirectory: URL { url.appendingPathComponent(".ssh", isDirectory: true) }
}
