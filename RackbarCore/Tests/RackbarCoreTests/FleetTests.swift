import Testing
@testable import RackbarCore

func makeServer(_ id: Int, _ name: String, ipv4: String? = nil, status: String = "running") -> Server {
    Server(id: id, name: name, status: status, locked: false, ipv4: ipv4, ipv4DNS: nil, ipv6: nil,
           privateIPs: [], typeName: "cx22", cores: 2, memoryGB: 4, diskGB: 40, image: "Ubuntu 24.04",
           osFlavor: "ubuntu", city: "Falkenstein", country: "DE", datacenter: "fsn1-dc14", created: "",
           backupWindow: nil, outgoingTraffic: nil, ingoingTraffic: nil, includedTraffic: nil,
           deleteProtected: false, rebuildProtected: false, rescueEnabled: false, firewallCount: 0,
           firewallPending: false, placementGroup: nil, labels: [:], volumes: [])
}

func makeProject(_ label: String, _ servers: [Server], error: String? = nil) -> Project {
    Project(label: label, servers: servers, storageBoxes: [], error: error, status: error == nil ? 200 : 401,
            storageBoxesError: nil, isStale: false)
}

@Suite("Merging tokens into projects")
struct FleetTests {
    let accounts = [Account(label: "acme", keys: ["acme", "acme-2"]),
                    Account(label: "staging", keys: ["staging"])]

    @Test func tokensUnderOneLabelArePooledWithoutDuplicates() {
        let projects = Fleet.merge([
            KeyFetch(key: "acme", result: .success(ProjectData(
                servers: [makeServer(2, "web-2"), makeServer(1, "web-10")], storageBoxes: []))),
            KeyFetch(key: "acme-2", result: .success(ProjectData(
                servers: [makeServer(2, "web-2"), makeServer(3, "db-1")], storageBoxes: []))),
            KeyFetch(key: "staging", result: .success(ProjectData(servers: [], storageBoxes: []))),
        ], accounts: accounts)

        #expect(projects.map(\.label) == ["acme", "staging"])
        // Natural order: web-2 before web-10.
        #expect(projects[0].servers.map(\.name) == ["db-1", "web-2", "web-10"])
        #expect(projects.allSatisfy { $0.isOK })
    }

    @Test func oneFailingTokenMarksItsLabelButKeepsTheOthersServers() {
        let projects = Fleet.merge([
            KeyFetch(key: "acme", result: .success(ProjectData(servers: [makeServer(1, "web-1")], storageBoxes: []))),
            KeyFetch(key: "acme-2", result: .failure(FetchFailure(status: 401, message: "Token invalid or revoked"))),
        ], accounts: accounts)

        #expect(projects[0].servers.map(\.name) == ["web-1"])
        #expect(projects[0].error == "Token invalid or revoked")
        #expect(projects[0].status == 401)
        #expect(!Fleet.canSyncSSH(projects))
    }

    @Test func aFailedProjectKeepsLastRoundsListButIsNeverSynced() {
        let lastGood = [makeProject("acme", [makeServer(1, "web-1", ipv4: "203.0.113.10")])]
        let thisRound = [makeProject("acme", [], error: "Hetzner did not answer in time")]

        let retained = Fleet.retainingPrevious(thisRound, previous: lastGood)
        #expect(retained[0].servers.map(\.name) == ["web-1"])
        #expect(retained[0].isStale)
        #expect(retained[0].error == "Hetzner did not answer in time")
        #expect(!Fleet.canSyncSSH(retained))

        #expect(Fleet.retainingPrevious(thisRound, previous: [])[0].servers.isEmpty)
        #expect(Fleet.retainingPrevious(lastGood, previous: thisRound)[0].servers.count == 1)
    }

    @Test func onlyACompletePictureIsSynced() {
        let ok = [makeProject("acme", [])]
        #expect(Fleet.canSyncSSH(ok))
        #expect(!Fleet.canSyncSSH([]))
        #expect(!Fleet.canSyncSSH(ok + [makeProject("broken", [], error: "401")]))
    }

    @Test func hostsAreNamespacedSortedAndOnlyWithAnIPv4() {
        let hosts = Fleet.sshHosts([
            makeProject("Zeta Produktion", [makeServer(1, "web-1", ipv4: "203.0.113.10"),
                                            makeServer(2, "private-only")]),
            makeProject("staging", [makeServer(3, "app-1", ipv4: "198.51.100.20")]),
        ])
        #expect(hosts == [SSHHost(alias: "staging/app-1", hostName: "198.51.100.20"),
                          SSHHost(alias: "zeta-produktion/web-1", hostName: "203.0.113.10")])
    }

    @Test func twoLabelsFoldingToOneNamespaceWriteEachAliasOnce() {
        let hosts = Fleet.sshHosts([
            makeProject("Acme", [makeServer(1, "web-1", ipv4: "203.0.113.10")]),
            makeProject("acme", [makeServer(2, "web-1", ipv4: "203.0.113.99")]),
        ])
        #expect(hosts == [SSHHost(alias: "acme/web-1", hostName: "203.0.113.10")])
    }

    @Test func theDemoFleetDecodesLikeTheAPI() throws {
        let projects = DemoFleet.projects()
        #expect(projects.map(\.label) == ["production", "staging"])
        let production = try #require(projects.first)
        #expect(production.servers.count == 6)
        #expect(production.storageBoxes.count == 1)

        let db = try #require(production.servers.first { $0.name == "db-1" })
        #expect(db.ipv4 == "203.0.113.11")
        #expect(db.volumes.map(\.name) == ["pg-data"])
        #expect(db.tone == .live)

        let bastion = try #require(production.servers.first { $0.name == "bastion" })
        #expect(bastion.locked)
        #expect(bastion.tone == .bad)
        #expect(production.servers.first { $0.name == "worker-1" }?.tone == .busy)
        #expect(production.servers.first { $0.name == "cache-1" }?.tone == .off)

        let box = try #require(production.storageBoxes.first)
        #expect(box.host == "u123456.your-storagebox.de")
        #expect(box.sshTarget == "u123456@u123456.your-storagebox.de")
        #expect(box.services == ["SSH", "Samba"])
        #expect(box.fill > 0.28 && box.fill < 0.29)

        #expect(Fleet.sshHosts(projects).count == 9)
    }
}
