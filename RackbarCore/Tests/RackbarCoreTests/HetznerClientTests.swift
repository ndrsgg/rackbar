import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import RackbarCore

/// Answers for Hetzner from a table of path + page → response.
final class FakeTransport: HTTPTransport {
    enum Answer: Sendable {
        case json(String, status: Int = 200)
        case timeout
    }

    private let answers: [String: [Answer]]
    private let state = Mutex<(calls: [String], served: [String: Int])>((calls: [], served: [:]))

    /// `answers["/v1/servers?page=1"]` is served in turn on each call; the
    /// last one repeats.
    init(_ answers: [String: [Answer]]) {
        self.answers = answers
    }

    var calls: [String] { state.withLock { $0.calls } }

    func get(_ url: URL, token: String, timeout: Duration, limit: Int) async throws -> (Data, Int) {
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value ?? "1"
        let key = "\(url.path)?page=\(page)"
        let answer: Answer? = state.withLock { state in
            state.calls.append(key)
            guard let list = answers[key], !list.isEmpty else { return nil }
            let index = min(state.served[key, default: 0], list.count - 1)
            state.served[key, default: 0] += 1
            return list[index]
        }
        switch answer {
        case .json(let body, let status): return (Data(body.utf8), status)
        case .timeout: throw URLError(.timedOut)
        case nil: return (Data(#"{"error":{"message":"not found"}}"#.utf8), 404)
        }
    }
}

private func servers(_ names: [String], firstID: Int = 1, nextPage: Int? = nil) -> FakeTransport.Answer {
    let list = names.enumerated().map { index, name in
        #"{"id":\#(firstID + index),"name":"\#(name)","status":"running","public_net":{"ipv4":{"ip":"203.0.113.\#(index + 1)"}},"labels":{"env_name":"prod"},"volumes":[7]}"#
    }.joined(separator: ",")
    let next = nextPage.map(String.init) ?? "null"
    return .json(#"{"servers":[\#(list)],"meta":{"pagination":{"page":1,"next_page":\#(next)}}}"#)
}

private let volumes = FakeTransport.Answer.json(
    #"{"volumes":[{"id":7,"server":1,"name":"data","size":50,"linux_device":"/dev/sdb"}],"meta":{"pagination":{"next_page":null}}}"#)
private let noBoxes = FakeTransport.Answer.json(#"{"storage_boxes":[],"meta":{"pagination":{"next_page":null}}}"#)

@Suite("The Hetzner client")
struct HetznerClientTests {
    @Test func followsPagesAndJoinsVolumes() async throws {
        let transport = FakeTransport([
            "/v1/servers?page=1": [servers(["web-1", "web-2"], nextPage: 2)],
            "/v1/servers?page=2": [servers(["db-1"], firstID: 101)],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let data = try await HetznerClient(transport: transport).project(token: "t").get()

        #expect(data.servers.map(\.name) == ["web-1", "web-2", "db-1"])
        #expect(data.servers[0].volumes.map(\.device) == ["/dev/sdb"])
        // Label keys arrive as Hetzner wrote them, not camel-cased.
        #expect(data.servers[0].labels == ["env_name": "prod"])
        #expect(data.storageBoxesError == nil)
    }

    /// A server as the API sends it today: the location at the top, no
    /// datacenter, and the IPv6 network's reverse names as a list.
    @Test func readsTheServerAsHetznerSendsItToday() async throws {
        let server = #"""
            {"id":1,"name":"web-1","status":"running","locked":false,
             "location":{"id":1,"name":"fsn1","city":"Falkenstein","country":"DE","network_zone":"eu-central"},
             "server_type":{"id":1,"name":"cx22","cores":2,"memory":4,"disk":40},
             "public_net":{"firewalls":[],"floating_ips":[],
               "ipv4":{"id":1,"ip":"203.0.113.10","blocked":false,"dns_ptr":"static.example.com"},
               "ipv6":{"id":2,"ip":"2001:db8::/64","blocked":false,
                       "dns_ptr":[{"ip":"2001:db8::1","dns_ptr":"web-1.example.com"}]}},
             "private_net":[{"ip":"10.0.0.2","alias_ips":[],"mac_address":"86:00:00:00:00:01","network":1}],
             "labels":{},"volumes":[]}
            """#
        let transport = FakeTransport([
            "/v1/servers?page=1": [.json(#"{"servers":[\#(server)],"meta":{"pagination":{"next_page":null}}}"#)],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let data = try await HetznerClient(transport: transport).project(token: "t").get()

        let web = try #require(data.servers.first)
        #expect(web.ipv4 == "203.0.113.10")
        #expect(web.ipv4DNS == "static.example.com")
        #expect(web.ipv6 == "2001:db8::/64")
        #expect(web.city == "Falkenstein")
        #expect(web.country == "DE")
    }

    @Test func aRunawayNextPageStops() async throws {
        let transport = FakeTransport([
            "/v1/servers?page=1": [servers(["web-1"], nextPage: 1)],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let data = try await HetznerClient(transport: transport).project(token: "t").get()
        #expect(data.servers.count == 1)
    }

    @Test func aTimeoutIsRetriedOnce() async throws {
        let transport = FakeTransport([
            "/v1/servers?page=1": [.timeout, servers(["web-1"])],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let data = try await HetznerClient(transport: transport).project(token: "t").get()
        #expect(data.servers.map(\.name) == ["web-1"])
        #expect(transport.calls.filter { $0 == "/v1/servers?page=1" }.count == 2)
    }

    @Test func twoTimeoutsFailTheProject() async {
        let transport = FakeTransport([
            "/v1/servers?page=1": [.timeout],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let result = await HetznerClient(transport: transport).project(token: "t")
        #expect(throws: FetchFailure(status: 0, message: "Hetzner did not answer in time")) { try result.get() }
    }

    @Test func aRevokedTokenSaysSo() async {
        let transport = FakeTransport([
            "/v1/servers?page=1": [.json(#"{"error":{"code":"unauthorized","message":"unable to authenticate"}}"#, status: 401)],
            "/v1/volumes?page=1": [.json("{}", status: 401)],
            "/v1/storage_boxes?page=1": [.json("{}", status: 401)],
        ])
        let result = await HetznerClient(transport: transport).project(token: "t")
        #expect(throws: FetchFailure(status: 401, message: "unable to authenticate")) { try result.get() }
    }

    @Test func failedVolumesAndBoxesDoNotTakeTheListDown() async throws {
        let transport = FakeTransport([
            "/v1/servers?page=1": [servers(["web-1"])],
            "/v1/volumes?page=1": [.json("oops", status: 500)],
            "/v1/storage_boxes?page=1": [.timeout],
        ])
        let data = try await HetznerClient(transport: transport).project(token: "t").get()
        #expect(data.servers.map(\.name) == ["web-1"])
        #expect(data.servers[0].volumes.isEmpty)
        #expect(data.storageBoxesError == "Hetzner did not answer in time")
        // Boxes get one try, not two.
        #expect(transport.calls.filter { $0 == "/v1/storage_boxes?page=1" }.count == 1)
    }

    @Test func anUnexpectedShapeIsAnErrorNotACrash() async {
        let transport = FakeTransport([
            "/v1/servers?page=1": [.json(#"{"servers":[{"id":"not a number"}]}"#)],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let result = await HetznerClient(transport: transport).project(token: "t")
        #expect(throws: FetchFailure.self) { try result.get() }
    }

    @Test func fleetKeepsTheOrderOfKeysAndReportsAMissingToken() async {
        let transport = FakeTransport([
            "/v1/servers?page=1": [servers(["web-1"])],
            "/v1/volumes?page=1": [volumes],
            "/v1/storage_boxes?page=1": [noBoxes],
        ])
        let fetches = await HetznerClient(transport: transport).fleet(keys: ["a", "b", "c", "d", "e", "gone"]) { key in
            key == "gone" ? nil : "token-\(key)"
        }
        #expect(fetches.map(\.key) == ["a", "b", "c", "d", "e", "gone"])
        #expect(throws: FetchFailure(status: 0, message: "No token in the Keychain for \"gone\"")) {
            try fetches[5].result.get()
        }
    }
}

@Suite("Against the real API", .enabled(if: ProcessInfo.processInfo.environment["RACKBAR_LIVE"] != nil))
struct LiveTests {
    /// `RACKBAR_LIVE=1 swift test` — no token needed, an invalid one is the point.
    @Test func anInvalidTokenIsRefusedWithHetznersOwnWords() async {
        let result = await HetznerClient().project(token: "rackbar-invalid-token")
        #expect(throws: FetchFailure.self) { try result.get() }
        if case .failure(let failure) = result {
            #expect(failure.status == 401)
            #expect(!failure.message.isEmpty)
        }
    }
}
