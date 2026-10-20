import Foundation

/// An invented fleet for previews, screenshots and a first look without a
/// token. Addresses are from the RFC 5737 and RFC 3849 documentation ranges;
/// nothing here exists. Same file as the Omarchy plugin's `demo/fleet.json`.
public enum DemoFleet {
    public static let accounts = [
        Account(label: "production", keys: ["production"]),
        Account(label: "staging", keys: ["staging"]),
    ]

    public static func projects() -> [Project] {
        guard let url = Bundle.module.url(forResource: "demo-fleet", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        let fetches = accounts.map { account in
            let entry = file.projects[account.label]
            return KeyFetch(key: account.label, result: .success(ProjectData(
                servers: joinVolumes(servers: entry?.servers ?? [], volumes: entry?.volumes ?? []),
                storageBoxes: (entry?.storageBoxes ?? []).map(\.box)
            )))
        }
        return Fleet.merge(fetches, accounts: accounts)
    }

    private struct File: Decodable {
        struct Entry: Decodable {
            var servers: [APIServer]?
            var volumes: [APIVolume]?
            var storageBoxes: [APIStorageBox]?
            enum CodingKeys: String, CodingKey {
                case servers, volumes
                case storageBoxes = "storage_boxes"
            }
        }
        var projects: [String: Entry]
    }
}
