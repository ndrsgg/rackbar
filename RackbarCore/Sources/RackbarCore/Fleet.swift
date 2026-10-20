import Foundation

/// What one token returned.
public struct ProjectData: Sendable {
    public var servers: [Server]
    public var storageBoxes: [StorageBox]
    /// Boxes live on another host and fail on their own; the list does not.
    public var storageBoxesError: String?
    public var timings: [String: Duration]

    public init(servers: [Server], storageBoxes: [StorageBox], storageBoxesError: String? = nil,
                timings: [String: Duration] = [:]) {
        self.servers = servers
        self.storageBoxes = storageBoxes
        self.storageBoxesError = storageBoxesError
        self.timings = timings
    }
}

public struct FetchFailure: Error, Sendable, Equatable {
    /// The HTTP status, or 0 when there was none.
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

/// One Keychain key and what came back for it.
public struct KeyFetch: Sendable {
    public var key: String
    public var result: Result<ProjectData, FetchFailure>

    public init(key: String, result: Result<ProjectData, FetchFailure>) {
        self.key = key
        self.result = result
    }
}

/// A label with everything its tokens returned, merged.
public struct Project: Identifiable, Sendable {
    public var label: String
    public var servers: [Server]
    public var storageBoxes: [StorageBox]
    /// Set when any token under the label failed. The servers the other
    /// tokens returned are still here.
    public var error: String?
    public var status: Int
    public var storageBoxesError: String?
    /// Failed this round and shows last round's list under the error.
    public var isStale: Bool

    public var id: String { label }
    public var isOK: Bool { error == nil }
    public var namespace: String { sshNamespace(for: label) }
}

public enum Fleet {
    /// Answers come per Keychain key; a label may own several. They are pooled
    /// back under it here: servers and boxes merged, duplicates dropped, and
    /// one failing token marked against its label without hiding what the
    /// others returned. Labels keep the order of `accounts`.
    public static func merge(_ fetches: [KeyFetch], accounts: [Account]) -> [Project] {
        var order: [String] = []
        var byLabel: [String: Project] = [:]
        var seenServers: [String: Set<Int>] = [:]
        var seenBoxes: [String: Set<Int>] = [:]

        for fetch in fetches {
            let label = accounts.label(forKey: fetch.key)
            if byLabel[label] == nil {
                order.append(label)
                byLabel[label] = Project(label: label, servers: [], storageBoxes: [], error: nil,
                                         status: 200, storageBoxesError: nil, isStale: false)
            }
            switch fetch.result {
            case .failure(let failure):
                byLabel[label]!.status = failure.status
                byLabel[label]!.error = [byLabel[label]!.error, failure.message].compactMap { $0 }.joined(separator: " · ")
            case .success(let data):
                for server in data.servers where seenServers[label, default: []].insert(server.id).inserted {
                    byLabel[label]!.servers.append(server)
                }
                for box in data.storageBoxes where seenBoxes[label, default: []].insert(box.id).inserted {
                    byLabel[label]!.storageBoxes.append(box)
                }
                if byLabel[label]!.storageBoxesError == nil {
                    byLabel[label]!.storageBoxesError = data.storageBoxesError
                }
            }
        }

        let rank = Dictionary(accounts.enumerated().map { ($1.label, $0) }, uniquingKeysWith: { first, _ in first })
        return order
            .sorted { (rank[$0] ?? .max, order.firstIndex(of: $0)!) < (rank[$1] ?? .max, order.firstIndex(of: $1)!) }
            .map { label in
                var project = byLabel[label]!
                project.servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                project.storageBoxes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return project
            }
    }

    /// A project that failed this round keeps what it showed last round. A
    /// read that timed out once was blanking whole groups; the stale list
    /// under the error is more use than an empty one, and `canSyncSSH` still
    /// refuses it.
    public static func retainingPrevious(_ next: [Project], previous: [Project]) -> [Project] {
        let old = Dictionary(previous.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        return next.map { project in
            guard !project.isOK, project.servers.isEmpty, project.storageBoxes.isEmpty,
                  let kept = old[project.label], !(kept.servers.isEmpty && kept.storageBoxes.isEmpty)
            else { return project }
            var merged = project
            merged.servers = kept.servers
            merged.storageBoxes = kept.storageBoxes
            merged.isStale = true
            return merged
        }
    }

    /// A project that failed to load has no servers, and writing that would
    /// delete its hosts over a passing 401 or a dropped network. Only a
    /// complete picture is safe to write.
    public static func canSyncSSH(_ projects: [Project]) -> Bool {
        !projects.isEmpty && projects.allSatisfy(\.isOK)
    }

    /// One `Host` per server with a public IPv4, sorted, each alias once.
    public static func sshHosts(_ projects: [Project]) -> [SSHHost] {
        var seen = Set<String>()
        var hosts: [SSHHost] = []
        for project in projects {
            let namespace = project.namespace
            for server in project.servers {
                guard let ip = server.ipv4 else { continue }
                let alias = sshAlias(namespace: namespace, server: server.name)
                guard !alias.isEmpty, seen.insert(alias).inserted else { continue }
                hosts.append(SSHHost(alias: alias, hostName: ip))
            }
        }
        return hosts.sorted { $0.alias < $1.alias }
    }

    /// A box reported under several tokens stays with the first project that
    /// had it rather than being listed twice.
    public static func dedupingStorageBoxes(_ projects: [Project]) -> [Project] {
        var seen = Set<Int>()
        return projects.map { project in
            var copy = project
            copy.storageBoxes = project.storageBoxes.filter { seen.insert($0.id).inserted }
            return copy
        }
    }
}
