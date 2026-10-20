import Testing
@testable import RackbarCore

@Suite("Labels, keys and namespaces")
struct AccountsTests {
    @Test("a label folds into an ssh namespace", arguments: [
        ("acme", "acme"),
        ("K8S", "k8s"),
        ("Zeta Produktion", "zeta-produktion"),
        ("kunde/alt", "kunde-alt"),
        ("Räume", "raeume"),
        ("Zürich", "zuerich"),
        ("  --x--  ", "x"),
        ("a -- b", "a-b"),
        ("", "project"),
        ("🙂", "project"),
    ])
    func namespace(label: String, expected: String) {
        #expect(sshNamespace(for: label) == expected)
    }

    @Test func aliasJoinsNamespaceAndServer() {
        #expect(sshAlias(namespace: "acme", server: "web-1") == "acme/web-1")
        #expect(sshAlias(namespace: "", server: "web-1") == "web-1")
        #expect(sshAlias(namespace: "acme", server: "") == "")
    }

    @Test func firstKeyIsTheLabelAndLaterOnesCountUp() {
        var accounts: [Account] = []
        #expect(accounts.nextKey(for: "acme") == "acme")
        accounts = accounts.adding(key: "acme", toLabel: "acme")
        #expect(accounts.nextKey(for: "acme") == "acme-2")
        accounts = accounts.adding(key: "acme-2", toLabel: "acme")
        #expect(accounts.nextKey(for: "acme") == "acme-3")
        #expect(accounts.nextKey(for: "  ") == nil)
    }

    @Test func aSecondTokenJoinsItsLabel() {
        let accounts = [Account(label: "acme", keys: ["acme"])]
            .adding(key: "acme-2", toLabel: "acme")
            .adding(key: "staging", toLabel: "staging")
        #expect(accounts == [Account(label: "acme", keys: ["acme", "acme-2"]),
                             Account(label: "staging", keys: ["staging"])])
        #expect(accounts.allKeys == ["acme", "acme-2", "staging"])
        #expect(accounts.label(forKey: "acme-2") == "acme")
        #expect(accounts.label(forKey: "unknown") == "unknown")
    }

    @Test func removingALabelTakesEveryKey() {
        let accounts = [Account(label: "acme", keys: ["acme", "acme-2"]),
                        Account(label: "staging", keys: ["staging"])]
        #expect(accounts.removing(label: "acme") == [Account(label: "staging", keys: ["staging"])])
    }
}
