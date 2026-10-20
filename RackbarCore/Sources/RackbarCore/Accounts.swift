import Foundation

/// A label and the Keychain keys of the tokens filed under it.
///
/// Hetzner Cloud tokens are scoped to one project and the API has no
/// `/projects`, so "all my projects" means one token per project. A label is
/// what you group them under: the heading in the list and the namespace in
/// the ssh config. One customer spread over three Hetzner projects is one
/// label with three keys, and `ssh acme/web-1` stops caring which project a
/// machine came from.
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var keys: [String]
    public var id: String { label }

    public init(label: String, keys: [String]) {
        self.label = label
        self.keys = keys
    }

    /// What this label becomes in front of the slash in `ssh label/server`.
    public var namespace: String { sshNamespace(for: label) }
}

extension Array where Element == Account {
    /// Every Keychain key, in the order the API should be asked.
    public var allKeys: [String] { flatMap(\.keys) }

    public func label(forKey key: String) -> String {
        first { $0.keys.contains(key) }?.label ?? key
    }

    public func account(labelled label: String) -> Account? {
        first { $0.label == label.trimmingCharacters(in: .whitespaces) }
    }

    /// A fresh Keychain key for another token under `label`. The first is the
    /// label itself; later ones count up from `label-2`.
    public func nextKey(for label: String) -> String? {
        let name = label.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let taken = Set(allKeys)
        if !taken.contains(name) { return name }
        return (2..<1000).lazy.map { "\(name)-\($0)" }.first { !taken.contains($0) }
    }

    public func adding(key: String, toLabel label: String) -> [Account] {
        let name = label.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !key.isEmpty else { return self }
        var next = self
        if let index = next.firstIndex(where: { $0.label == name }) {
            if !next[index].keys.contains(key) { next[index].keys.append(key) }
        } else {
            next.append(Account(label: name, keys: [key]))
        }
        return next
    }

    /// Dropping a label drops every key under it, and its namespace with it.
    public func removing(label: String) -> [Account] {
        filter { $0.label != label }
    }
}

/// One name, not two: the label is what you call the project here and what
/// you ssh to. A label may carry spaces, capitals or a slash, an ssh `Host`
/// pattern had better not, so the namespace is derived rather than typed a
/// second time. `Zeta Produktion` becomes `zeta-produktion`.
public func sshNamespace(for label: String) -> String {
    var alias = label.lowercased()
    // Fold the letters a German or French project name is likely to carry,
    // rather than dropping them and turning "Räume" into "r-ume".
    for (from, to) in aliasFold {
        alias = alias.replacingOccurrences(of: from, with: to)
    }
    var folded = ""
    var lastWasDash = false
    for scalar in alias.unicodeScalars {
        // The slash is the separator between namespace and server, so a slash
        // inside a label becomes a dash like any other foreign character.
        let kept: Unicode.Scalar = isAliasScalar(scalar) && scalar != "/" ? scalar : "-"
        if kept == "-" && lastWasDash { continue }
        folded.unicodeScalars.append(kept)
        lastWasDash = kept == "-"
    }
    let trimmed = folded.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return trimmed.isEmpty ? "project" : trimmed
}

/// `namespace/server`, or just the server when there is no namespace.
public func sshAlias(namespace: String, server: String) -> String {
    guard !server.isEmpty else { return "" }
    return namespace.isEmpty ? server : "\(namespace)/\(server)"
}

private let aliasFold: [(String, String)] = [
    ("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"),
    ("á", "a"), ("à", "a"), ("é", "e"), ("è", "e"), ("í", "i"),
    ("ó", "o"), ("ú", "u"), ("ñ", "n"), ("ç", "c"),
]

/// `[A-Za-z0-9._/-]`: what may stand in an ssh `Host` line Rackbar writes.
func isAliasScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "/", "-": true
    default: false
    }
}
