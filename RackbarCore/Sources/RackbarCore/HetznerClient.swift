import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One GET with a bearer token. A protocol so the tests can answer for
/// Hetzner.
public protocol HTTPTransport: Sendable {
    /// The body and the status. Refuses, rather than truncates, a body over
    /// `limit` bytes, and throws `URLError(.timedOut)` past `timeout`.
    func get(_ url: URL, token: String, timeout: Duration, limit: Int) async throws -> (Data, Int)
}

public struct HTTPBodyTooLarge: Error {}

/// Read-only access to the Hetzner Cloud API for one project token.
///
/// A refresh costs three requests per token — the servers, the volumes and
/// the storage boxes — made side by side, so it takes as long as the slowest.
public struct HetznerClient: Sendable {
    public static let cloudAPI = URL(string: "https://api.hetzner.cloud/v1")!
    /// Storage Boxes are absent from the Cloud API; Hetzner's newer API
    /// serves them to the same project token.
    public static let unifiedAPI = URL(string: "https://api.hetzner.com/v1")!

    /// Hetzner answers in well under a second; past this the network is
    /// gone. One slow answer is retried once before it counts.
    static let timeout: Duration = .seconds(15)
    static let attempts = 2
    /// Boxes are the least of what the panel shows and must not hold the list.
    static let boxTimeout: Duration = .seconds(6)
    static let boxAttempts = 1

    static let perPage = 100
    static let maxPages = 50
    static let maxItems = 2000
    static let maxBody = 4 * 1024 * 1024
    static let maxErrorBody = 64 * 1024

    let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Everything one token can see. Never throws: a failure is something to
    /// show under the project's heading.
    public func project(token: String) async -> Result<ProjectData, FetchFailure> {
        let clock = ContinuousClock()
        async let servers = timed(clock) {
            try await fetchAll(Self.cloudAPI.appendingPathComponent("servers"), key: "servers",
                               token: token, as: APIServer.self)
        }
        async let volumes = timed(clock) {
            try await fetchAll(Self.cloudAPI.appendingPathComponent("volumes"), key: "volumes",
                               token: token, as: APIVolume.self)
        }
        async let boxes = timed(clock) {
            try await fetchAll(Self.unifiedAPI.appendingPathComponent("storage_boxes"), key: "storage_boxes",
                               token: token, as: APIStorageBox.self,
                               timeout: Self.boxTimeout, attempts: Self.boxAttempts)
        }
        let (serverResult, serverTime) = await servers
        let (volumeResult, volumeTime) = await volumes
        let (boxResult, boxTime) = await boxes

        let rawServers: [APIServer]
        switch serverResult {
        case .success(let list): rawServers = list
        case .failure(let error): return .failure(Self.failure(for: error))
        }
        var storageBoxes: [StorageBox] = []
        var storageBoxesError: String?
        switch boxResult {
        case .success(let list): storageBoxes = list.map(\.box)
        case .failure(let error): storageBoxesError = Self.failure(for: error).message
        }
        // Volumes are detail; the list is worth showing without them.
        let rawVolumes = (try? volumeResult.get()) ?? []

        return .success(ProjectData(
            servers: joinVolumes(servers: rawServers, volumes: rawVolumes),
            storageBoxes: storageBoxes,
            storageBoxesError: storageBoxesError,
            timings: ["servers": serverTime, "volumes": volumeTime, "storage_boxes": boxTime]
        ))
    }

    /// Every token's answer, at most four at a time, in the order given.
    public func fleet(keys: [String], token: @escaping @Sendable (String) -> String?) async -> [KeyFetch] {
        await withTaskGroup(of: (Int, KeyFetch).self) { group in
            var results: [KeyFetch?] = Array(repeating: nil, count: keys.count)
            var next = 0
            func start() {
                guard next < keys.count else { return }
                let index = next
                let key = keys[index]
                next += 1
                group.addTask {
                    guard let secret = token(key) else {
                        return (index, KeyFetch(key: key, result: .failure(
                            FetchFailure(status: 0, message: "No token in the Keychain for \"\(key)\""))))
                    }
                    return (index, KeyFetch(key: key, result: await project(token: secret)))
                }
            }
            for _ in 0..<4 { start() }
            for await (index, fetch) in group {
                results[index] = fetch
                start()
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: - Paging

    func fetchAll<Item: Decodable>(_ url: URL, key: String, token: String, as _: Item.Type,
                                   timeout: Duration = timeout, attempts: Int = attempts) async throws -> [Item] {
        var items: [Item] = []
        var page = 1
        for _ in 0..<Self.maxPages {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "per_page", value: String(Self.perPage)),
                                     URLQueryItem(name: "page", value: String(page))]
            let body = try await get(components.url!, token: token, timeout: timeout, attempts: attempts)
            let decoder = JSONDecoder()
            decoder.userInfo[Page<Item>.listKey] = key
            let decoded = try decoder.decode(Page<Item>.self, from: body)
            items += decoded.items
            if items.count > Self.maxItems {
                throw FetchFailure(status: 0, message: "More than \(Self.maxItems) \(key) in one project")
            }
            // A runaway next_page would otherwise loop against a broken API.
            guard let nextPage = decoded.nextPage, nextPage > page else { break }
            page = nextPage
        }
        return items
    }

    func get(_ url: URL, token: String, timeout: Duration, attempts: Int) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (body, status) = try await transport.get(url, token: token, timeout: timeout, limit: Self.maxBody)
                guard (200..<300).contains(status) else { throw HTTPStatus(code: status, body: body) }
                return body
            } catch let error as URLError where error.code == .timedOut && attempt < attempts {
                continue
            }
        }
    }

    // MARK: - Errors

    struct HTTPStatus: Error {
        var code: Int
        var body: Data
    }

    /// Turns a failure into something the panel can show as it is.
    static func failure(for error: any Error) -> FetchFailure {
        switch error {
        case let failure as FetchFailure:
            return failure
        case let status as HTTPStatus:
            let detail = hetznerMessage(status.body.prefix(maxErrorBody))
            let code = status.code
            let fallback = switch code {
            case 401: "Token invalid or revoked"
            case 403: "Token lacks permission for this project"
            case 429: "Rate limited by Hetzner — try again shortly"
            case 500...: "Hetzner Cloud API is unavailable (\(code))"
            default: "Hetzner Cloud API error \(code)"
            }
            return FetchFailure(status: code, message: detail ?? fallback)
        case let error as URLError where error.code == .timedOut:
            return FetchFailure(status: 0, message: "Hetzner did not answer in time")
        case let error as URLError:
            return FetchFailure(status: 0, message: "No connection to Hetzner (\(error.localizedDescription))")
        case is HTTPBodyTooLarge:
            return FetchFailure(status: 0, message: "Hetzner's answer was larger than Rackbar reads")
        case is DecodingError:
            return FetchFailure(status: 0, message: "Hetzner answered in a shape Rackbar does not understand")
        default:
            return FetchFailure(status: 0, message: error.localizedDescription)
        }
    }

    static func hetznerMessage(_ body: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner?
        }
        let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
        guard let message, !message.isEmpty else { return nil }
        return String(message.prefix(256))
    }
}

/// `{ "<key>": [...], "meta": { "pagination": { "next_page": n } } }`
struct Page<Item: Decodable>: Decodable {
    static var listKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "rackbar.listKey")! }

    var items: [Item]
    var nextPage: Int?

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private struct Meta: Decodable {
        struct Pagination: Decodable {
            var nextPage: Int?
            enum CodingKeys: String, CodingKey { case nextPage = "next_page" }
        }
        var pagination: Pagination?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let key = Key(stringValue: decoder.userInfo[Self.listKey] as? String ?? "")
        items = try container.decodeIfPresent([Item].self, forKey: key) ?? []
        nextPage = try container.decodeIfPresent(Meta.self, forKey: Key(stringValue: "meta"))?.pagination?.nextPage
    }
}

private func timed<T: Sendable>(_ clock: ContinuousClock, _ work: () async throws -> T) async -> (Result<T, any Error>, Duration) {
    let start = clock.now
    do {
        let value = try await work()
        return (.success(value), clock.now - start)
    } catch {
        return (.failure(error), clock.now - start)
    }
}

// MARK: - URLSession

public struct URLSessionTransport: HTTPTransport {
    /// One ephemeral session for the life of the app: no cache, no cookies,
    /// nothing of a token on disk. Shared rather than made per client, since
    /// a session that is let go without being invalidated takes the process
    /// down on Linux.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Rackbar", "Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    public init() {}

    private var session: URLSession { Self.session }

    public func get(_ url: URL, token: String, timeout: Duration, limit: Int) async throws -> (Data, Int) {
        // URLSession's timeouts are between packets; this one is for the
        // whole answer, which is the one the panel cares about.
        try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            group.addTask { try await load(url, token: token, timeout: timeout, limit: limit) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func load(_ url: URL, token: String, timeout: Duration, limit: Int) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Double(timeout.components.seconds) + 1
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        guard data.count <= limit else { throw HTTPBodyTooLarge() }
        #else
        // Read to the ceiling plus one byte and refuse past it, so a broken or
        // hostile answer cannot make the app grow without bound.
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) { throw HTTPBodyTooLarge() }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw HTTPBodyTooLarge() }
        }
        #endif
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
