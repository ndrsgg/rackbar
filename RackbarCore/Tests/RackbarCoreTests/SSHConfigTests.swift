import Foundation
import Testing
@testable import RackbarCore

@Suite("The ssh config file")
struct SSHConfigTests {
    let hosts = [SSHHost(alias: "acme/web-1", hostName: "203.0.113.10"),
                 SSHHost(alias: "acme/db-1", hostName: "203.0.113.11")]

    @Test func rendersSortedHostsWithUserAndKey() throws {
        let text = try SSHConfigFile.render(hosts: hosts, user: "root", identityFile: "~/.ssh/work_ed25519")
        #expect(text.hasSuffix("""

            Host acme/db-1
                HostName 203.0.113.11
                User root
                IdentityFile ~/.ssh/work_ed25519

            Host acme/web-1
                HostName 203.0.113.10
                User root
                IdentityFile ~/.ssh/work_ed25519

            """))
        #expect(text.hasPrefix("# Written by Rackbar"))
    }

    @Test func leavesOutEmptyUserAndKey() throws {
        let text = try SSHConfigFile.render(hosts: [hosts[0]], user: "", identityFile: "")
        #expect(!text.contains("User"))
        #expect(!text.contains("IdentityFile"))
    }

    @Test func anUnchangedFleetRendersTheSameBytes() throws {
        let one = try SSHConfigFile.render(hosts: hosts, user: "root", identityFile: "")
        let two = try SSHConfigFile.render(hosts: hosts.reversed(), user: "root", identityFile: "")
        #expect(one == two)
    }

    @Test("anything that would not survive as one Host line is refused", arguments: [
        "acme/web\nProxyCommand evil",
        "acme/web 1",
        "-oProxyCommand=evil",
        "/web",
        "acme/wéb",
        "",
    ])
    func refusesAliases(alias: String) {
        #expect(throws: SSHConfigError.invalidAlias(alias)) {
            try SSHConfigFile.render(hosts: [SSHHost(alias: alias, hostName: "203.0.113.10")],
                                     user: "root", identityFile: "")
        }
    }

    @Test("a HostName that is not an address is refused", arguments: [
        "evil.example", "203.0.113.10\nProxyCommand evil", "203.0.113", "",
    ])
    func refusesAddresses(address: String) {
        #expect(throws: SSHConfigError.invalidAddress(alias: "acme/web-1", address: address)) {
            try SSHConfigFile.render(hosts: [SSHHost(alias: "acme/web-1", hostName: address)],
                                     user: "root", identityFile: "")
        }
    }

    @Test func acceptsIPv6() throws {
        _ = try SSHConfigFile.render(hosts: [SSHHost(alias: "acme/web-1", hostName: "2001:db8::1")],
                                     user: "", identityFile: "")
    }

    @Test func refusesUserAndKeyThatWouldBreakTheLine() {
        #expect(throws: SSHConfigError.invalidUser("root\nProxyCommand evil")) {
            try SSHConfigFile.render(hosts: hosts, user: "root\nProxyCommand evil", identityFile: "")
        }
        #expect(throws: SSHConfigError.invalidUser("deploy user")) {
            try SSHConfigFile.render(hosts: hosts, user: "deploy user", identityFile: "")
        }
        #expect(throws: SSHConfigError.invalidIdentityFile("~/my key")) {
            try SSHConfigFile.render(hosts: hosts, user: "root", identityFile: "~/my key")
        }
    }

    @Test func includePathIsRelativeInsideDotSSH() {
        let home = URL(fileURLWithPath: "/Users/jane", isDirectory: true)
        #expect(SSHConfigFile.includePath(folder: home.appendingPathComponent(".ssh/hcloud"), home: home)
                == "hcloud/config")
        #expect(SSHConfigFile.includePath(folder: home.appendingPathComponent("dotfiles/ssh/rackbar"), home: home)
                == "~/dotfiles/ssh/rackbar/config")
        #expect(SSHConfigFile.includePath(folder: home.appendingPathComponent("My Files/ssh"), home: home)
                == "\"~/My Files/ssh/config\"")
        #expect(SSHConfigFile.includePath(folder: URL(fileURLWithPath: "/opt/ssh"), home: home)
                == "/opt/ssh/config")
        #expect(SSHConfigFile.includeDirective(folder: home.appendingPathComponent(".ssh/hcloud"), home: home)
                == "Match all\nInclude hcloud/config")
    }

    @Test func appendCommandStartsWithANewlineAndSurvivesOddFolderNames() {
        let home = URL(fileURLWithPath: "/Users/jane", isDirectory: true)
        #expect(SSHConfigFile.appendCommand(folder: home.appendingPathComponent(".ssh/hcloud"), home: home)
                == #"printf '\nMatch all\nInclude hcloud/config\n' >> ~/.ssh/config"#)
        #expect(SSHConfigFile.appendCommand(folder: home.appendingPathComponent(".ssh/it's 100%"), home: home)
                == #"printf '\nMatch all\nInclude "it'\''s 100%%/config"\n' >> ~/.ssh/config"#)
    }
}

@Suite("Writing the ssh config file")
struct SSHConfigWriterTests {
    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rackbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesMode600AndLeavesNothingElseBehind() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SSHConfigWriter(folder: folder)

        #expect(try writer.write("Host a\n") == .written)
        #expect(try String(contentsOf: writer.fileURL, encoding: .utf8) == "Host a\n")
        let mode = try FileManager.default.attributesOfItem(atPath: writer.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config"])
    }

    @Test func anUnchangedFileIsNotRewritten() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SSHConfigWriter(folder: folder)

        #expect(try writer.write("Host a\n") == .written)
        #expect(try writer.write("Host a\n") == .unchanged)
        #expect(try writer.write("Host b\n") == .written)
        #expect(try String(contentsOf: writer.fileURL, encoding: .utf8) == "Host b\n")
    }

    @Test func refusesToReadAnOversizedFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = SSHConfigWriter(folder: folder)
        try Data(count: SSHConfigWriter.maxExisting + 1).write(to: writer.fileURL)

        #expect(throws: SSHConfigError.existingFileTooLarge) { try writer.write("Host a\n") }
    }

    @Test func aMissingFolderIsAnErrorNotACrash() {
        let writer = SSHConfigWriter(folder: URL(fileURLWithPath: "/nonexistent/rackbar-\(UUID().uuidString)"))
        #expect(throws: SSHConfigError.self) { try writer.write("Host a\n") }
    }
}
