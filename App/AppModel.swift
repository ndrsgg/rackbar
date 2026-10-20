import AppKit
import Observation
import RackbarCore

/// Everything the menu and the settings window share: the accounts, the
/// fleet as last fetched, and the ssh config that follows it.
@MainActor
@Observable
final class AppModel {
    // MARK: Settings, kept in UserDefaults. Tokens are not: they are in the Keychain.

    var accounts: [Account] {
        didSet { defaults.set(try? JSONEncoder().encode(accounts), forKey: Keys.accounts) }
    }

    /// Seconds between polls.
    var refreshInterval: Int {
        didSet {
            defaults.set(refreshInterval, forKey: Keys.refreshInterval)
            startPolling()
        }
    }

    var sshSyncEnabled: Bool {
        didSet {
            defaults.set(sshSyncEnabled, forKey: Keys.sshSyncEnabled)
            syncSSH()
        }
    }

    var sshUser: String {
        didSet {
            defaults.set(sshUser, forKey: Keys.sshUser)
            syncSSH()
        }
    }

    var sshIdentityFile: String {
        didSet {
            defaults.set(sshIdentityFile, forKey: Keys.sshIdentityFile)
            syncSSH()
        }
    }

    /// An invented fleet instead of the API, for a first look and screenshots.
    var demoMode: Bool {
        didSet {
            defaults.set(demoMode, forKey: Keys.demoMode)
            // Last round's lists must not survive into the other mode.
            projects = []
            lastRefresh = nil
            Task { await refresh() }
        }
    }

    // MARK: State

    private(set) var projects: [Project] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var sshStatus: SSHStatus = .off
    private(set) var lastCopied: String?

    let sshFolder = SSHFolder()

    private let client = HetznerClient()
    private let keychain = Keychain()
    private let defaults = UserDefaults.standard
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var copyResetTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        accounts = defaults.data(forKey: Keys.accounts)
            .flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        refreshInterval = defaults.object(forKey: Keys.refreshInterval) as? Int ?? 300
        sshSyncEnabled = defaults.bool(forKey: Keys.sshSyncEnabled)
        sshUser = defaults.string(forKey: Keys.sshUser) ?? "root"
        sshIdentityFile = defaults.string(forKey: Keys.sshIdentityFile) ?? ""
        demoMode = defaults.bool(forKey: Keys.demoMode)
        startPolling()
    }

    // MARK: Fetching

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if demoMode {
            projects = DemoFleet.projects()
        } else {
            let keychain = self.keychain
            let fetches = await client.fleet(keys: accounts.allKeys) { keychain.token(for: $0) }
            let merged = Fleet.dedupingStorageBoxes(Fleet.merge(fetches, accounts: accounts))
            projects = Fleet.retainingPrevious(merged, previous: projects)
        }
        lastRefresh = .now
        syncSSH()
    }

    /// Opening the menu does not fetch on its own — the poll is running —
    /// unless what is on screen is older than the interval or failed.
    func refreshIfStale() {
        let old = lastRefresh.map { Date.now.timeIntervalSince($0) > Double(refreshInterval) } ?? true
        if old || projects.contains(where: { !$0.isOK }) {
            Task { await refresh() }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.refreshInterval ?? 300
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: Accounts

    /// Proves the token against the API before keeping it, then files it
    /// under `label` — a new label, or another token for an existing one.
    /// Returns how many servers it sees.
    @discardableResult
    func addToken(_ rawToken: String, label rawLabel: String) async throws -> Int {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = rawLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { throw AddTokenError.noLabel }
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { throw AddTokenError.malformed }
        guard let key = accounts.nextKey(for: label) else { throw AddTokenError.tooMany }

        switch await client.project(token: token) {
        case .failure(let failure):
            throw AddTokenError.rejected(failure.message)
        case .success(let data):
            try keychain.store(token, for: key, label: label)
            accounts = accounts.adding(key: key, toLabel: label)
            await refresh()
            return data.servers.count
        }
    }

    /// Removes a label and every token under it. Its hosts leave the ssh
    /// config with this sync: that is the point of removing it.
    func remove(label: String) {
        guard let account = accounts.account(labelled: label) else { return }
        for key in account.keys {
            try? keychain.remove(key)
        }
        accounts = accounts.removing(label: label)
        projects.removeAll { $0.label == label }
        syncSSH()
    }

    func project(labelled label: String) -> Project? {
        projects.first { $0.label == label }
    }

    // MARK: ssh

    func syncSSH() {
        guard sshSyncEnabled else { sshStatus = .off; return }
        guard !demoMode else { sshStatus = .demo; return }
        guard sshFolder.url != nil else { sshStatus = .needsFolder; return }
        // With no accounts left, no hosts is the complete picture: removing
        // the last label must empty the file, not leave its hosts behind.
        guard accounts.isEmpty || Fleet.canSyncSSH(projects) else {
            let failed = projects.filter { !$0.isOK }.map(\.label)
            sshStatus = failed.isEmpty ? .waiting : .incomplete(failed)
            return
        }
        do {
            let hosts = Fleet.sshHosts(projects)
            let text = try SSHConfigFile.render(hosts: hosts, user: sshUser, identityFile: sshIdentityFile)
            let outcome = try sshFolder.withAccess { folder in
                try SSHConfigWriter(folder: folder).write(text)
            }
            sshStatus = .synced(hosts: hosts.count, at: .now, changed: outcome == .written)
        } catch {
            sshStatus = .failed(error.localizedDescription)
        }
    }

    /// The file as the next sync would write it.
    var sshPreview: String {
        do {
            return try SSHConfigFile.render(hosts: Fleet.sshHosts(projects), user: sshUser,
                                            identityFile: sshIdentityFile)
        } catch {
            return "# \(error.localizedDescription)"
        }
    }

    // MARK: Clipboard

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        lastCopied = value
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { lastCopied = nil }
        }
    }

    // MARK: Summary

    var serverCount: Int { projects.reduce(0) { $0 + $1.servers.count } }
    var failedCount: Int { projects.filter { !$0.isOK }.count }

    /// Badges the menu bar icon: a project failed to load, or the ssh config
    /// could not be written.
    var hasProblem: Bool {
        if case .failed = sshStatus { return true }
        return failedCount > 0
    }

    private enum Keys {
        static let accounts = "accounts"
        static let refreshInterval = "refreshInterval"
        static let sshSyncEnabled = "sshSyncEnabled"
        static let sshUser = "sshUser"
        static let sshIdentityFile = "sshIdentityFile"
        static let demoMode = "demoMode"
    }
}

enum SSHStatus: Equatable {
    case off
    case demo
    case needsFolder
    /// Nothing loaded yet.
    case waiting
    /// These labels failed to load, and writing without them would delete
    /// their hosts over a passing error.
    case incomplete([String])
    case synced(hosts: Int, at: Date, changed: Bool)
    case failed(String)
}

enum AddTokenError: LocalizedError {
    case noLabel
    case malformed
    case tooMany
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noLabel: "Give the project a label."
        case .malformed: "That does not look like a token: it is empty or has spaces in it."
        case .tooMany: "That label has as many tokens as Rackbar will keep."
        case .rejected(let message): "Hetzner refused the token: \(message)"
        }
    }
}
