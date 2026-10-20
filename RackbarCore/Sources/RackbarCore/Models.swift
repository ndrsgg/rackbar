import Foundation

/// The four ways a state is shown. Named after what a state *is*, not what it
/// looks like, so a theme change cannot make two of them mean the same thing.
public enum Tone: Sendable, Hashable {
    case live, off, busy, bad

    public init(serverStatus status: String) {
        switch status.lowercased() {
        case "running": self = .live
        case "off": self = .off
        case "starting", "stopping", "initializing", "migrating", "rebuilding", "deleting": self = .busy
        default: self = .bad
        }
    }
}

public struct Volume: Hashable, Sendable {
    public var name: String
    public var sizeGB: Int
    public var device: String
    public var format: String
    public var status: String
}

public struct Server: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var status: String
    public var locked: Bool
    public var ipv4: String?
    public var ipv4DNS: String?
    /// Hetzner hands out a /64 written as `2a01:…::/64`.
    public var ipv6: String?
    public var privateIPs: [String]
    public var typeName: String
    public var cores: Int?
    public var memoryGB: Double?
    public var diskGB: Int?
    public var image: String
    public var osFlavor: String?
    public var city: String
    public var country: String
    public var datacenter: String
    public var created: String
    public var backupWindow: String?
    public var outgoingTraffic: Int64?
    public var ingoingTraffic: Int64?
    public var includedTraffic: Int64?
    public var deleteProtected: Bool
    public var rebuildProtected: Bool
    public var rescueEnabled: Bool
    public var firewallCount: Int
    public var firewallPending: Bool
    public var placementGroup: String?
    public var labels: [String: String]
    public var volumes: [Volume]

    public var tone: Tone { locked ? .bad : Tone(serverStatus: status) }

    public var location: String {
        if !city.isEmpty, !country.isEmpty { return "\(city), \(country)" }
        return city.isEmpty ? (country.isEmpty ? datacenter : country) : city
    }

    public var privateIP: String? { privateIPs.first }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        var haystack = [name, status, ipv4 ?? "", ipv6 ?? "", privateIPs.joined(separator: " "),
                        typeName, location, image]
        haystack += labels.map { "\($0.key)=\($0.value)" }
        return haystack.joined(separator: " ").lowercased().contains(needle)
    }
}

public struct StorageBox: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var username: String
    /// The hostname to connect to, `u123456.your-storagebox.de`.
    public var host: String
    public var status: String
    public var product: String
    public var location: String
    public var quotaBytes: Int64
    public var usedBytes: Int64
    public var usedDataBytes: Int64
    public var usedSnapshotBytes: Int64
    public var services: [String]
    public var deleteProtected: Bool
    public var reachableExternally: Bool
    public var system: String
    public var created: String

    /// How full the box is, 0…1; `stats.size` is the one thing a cloud server
    /// cannot tell you about itself.
    public var fill: Double {
        quotaBytes > 0 ? min(1, Double(usedBytes) / Double(quotaBytes)) : 0
    }

    public var tone: Tone {
        if status != "active" || fill >= 0.9 { return .bad }
        return fill >= 0.75 ? .busy : .live
    }

    public var sshTarget: String? {
        username.isEmpty || host.isEmpty ? nil : "\(username)@\(host)"
    }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return true }
        return [name, host, username, product, location].joined(separator: " ").lowercased().contains(needle)
    }
}

// MARK: - What the API sends

// Every field optional: a field Hetzner drops tomorrow must not take a whole
// project off the list. A field that changes type does, and says so.

struct APIServer: Decodable {
    struct PublicNet: Decodable {
        struct Address: Decodable {
            var ip: String?
            var dnsPtr: String?
            enum CodingKeys: String, CodingKey { case ip, dnsPtr = "dns_ptr" }
        }
        struct Firewall: Decodable { var status: String? }
        var ipv4: Address?
        var ipv6: Address?
        var firewalls: [Firewall]?
    }
    struct PrivateNet: Decodable { var ip: String? }
    struct ServerType: Decodable { var name: String?; var cores: Int?; var memory: Double?; var disk: Int? }
    struct Datacenter: Decodable {
        struct Location: Decodable { var name: String?; var city: String?; var country: String? }
        var name: String?
        var location: Location?
    }
    struct Image: Decodable {
        var name: String?
        var description: String?
        var osFlavor: String?
        enum CodingKeys: String, CodingKey { case name, description, osFlavor = "os_flavor" }
    }
    struct Named: Decodable { var name: String? }
    struct Protection: Decodable { var delete: Bool?; var rebuild: Bool? }

    var id: Int
    var name: String?
    var status: String?
    var created: String?
    var locked: Bool?
    var backupWindow: String?
    var outgoingTraffic: Int64?
    var ingoingTraffic: Int64?
    var includedTraffic: Int64?
    var rescueEnabled: Bool?
    var publicNet: PublicNet?
    var privateNet: [PrivateNet]?
    var serverType: ServerType?
    var datacenter: Datacenter?
    var image: Image?
    var placementGroup: Named?
    var protection: Protection?
    var labels: [String: String]?

    // Spelled out rather than left to `.convertFromSnakeCase`, which would
    // rewrite the keys of `labels` as well.
    enum CodingKeys: String, CodingKey {
        case id, name, status, created, locked, datacenter, image, protection, labels
        case backupWindow = "backup_window"
        case outgoingTraffic = "outgoing_traffic"
        case ingoingTraffic = "ingoing_traffic"
        case includedTraffic = "included_traffic"
        case rescueEnabled = "rescue_enabled"
        case publicNet = "public_net"
        case privateNet = "private_net"
        case serverType = "server_type"
        case placementGroup = "placement_group"
    }

    func server(volumes: [Volume]) -> Server {
        let firewalls = publicNet?.firewalls ?? []
        return Server(
            id: id,
            name: name.nonEmpty ?? "Unnamed",
            status: status.nonEmpty ?? "unknown",
            locked: locked == true,
            ipv4: publicNet?.ipv4?.ip.nonEmpty,
            ipv4DNS: publicNet?.ipv4?.dnsPtr.nonEmpty,
            ipv6: publicNet?.ipv6?.ip.nonEmpty,
            privateIPs: (privateNet ?? []).compactMap { $0.ip.nonEmpty },
            typeName: serverType?.name ?? "",
            cores: serverType?.cores,
            memoryGB: serverType?.memory,
            diskGB: serverType?.disk,
            image: image?.description.nonEmpty ?? image?.name ?? "",
            osFlavor: image?.osFlavor.nonEmpty,
            city: datacenter?.location?.city ?? "",
            country: datacenter?.location?.country ?? "",
            datacenter: datacenter?.name ?? "",
            created: created ?? "",
            backupWindow: backupWindow.nonEmpty,
            outgoingTraffic: outgoingTraffic,
            ingoingTraffic: ingoingTraffic,
            includedTraffic: includedTraffic,
            deleteProtected: protection?.delete == true,
            rebuildProtected: protection?.rebuild == true,
            rescueEnabled: rescueEnabled == true,
            firewallCount: firewalls.count,
            firewallPending: firewalls.contains { $0.status != "applied" },
            placementGroup: placementGroup?.name.nonEmpty,
            labels: labels ?? [:],
            volumes: volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }
}

struct APIVolume: Decodable {
    var id: Int
    var server: Int?
    var name: String?
    var size: Int?
    var linuxDevice: String?
    var format: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, server, name, size, format, status
        case linuxDevice = "linux_device"
    }

    var volume: Volume {
        Volume(name: name ?? "", sizeGB: size ?? 0, device: linuxDevice ?? "",
               format: format ?? "", status: status ?? "")
    }
}

struct APIStorageBox: Decodable {
    struct BoxType: Decodable { var name: String?; var description: String?; var size: Int64? }
    struct Location: Decodable { var name: String?; var city: String?; var country: String? }
    struct Stats: Decodable {
        var size: Int64?
        var sizeData: Int64?
        var sizeSnapshots: Int64?
        enum CodingKeys: String, CodingKey {
            case size
            case sizeData = "size_data"
            case sizeSnapshots = "size_snapshots"
        }
    }
    struct Access: Decodable {
        var sshEnabled: Bool?
        var sambaEnabled: Bool?
        var webdavEnabled: Bool?
        var zfsEnabled: Bool?
        var reachableExternally: Bool?
        enum CodingKeys: String, CodingKey {
            case sshEnabled = "ssh_enabled"
            case sambaEnabled = "samba_enabled"
            case webdavEnabled = "webdav_enabled"
            case zfsEnabled = "zfs_enabled"
            case reachableExternally = "reachable_externally"
        }
    }
    struct Protection: Decodable { var delete: Bool? }

    var id: Int
    var username: String?
    var status: String?
    var name: String?
    var server: String?
    var system: String?
    var created: String?
    var storageBoxType: BoxType?
    var location: Location?
    var stats: Stats?
    var accessSettings: Access?
    var protection: Protection?

    enum CodingKeys: String, CodingKey {
        case id, username, status, name, server, system, created, location, stats, protection
        case storageBoxType = "storage_box_type"
        case accessSettings = "access_settings"
    }

    var box: StorageBox {
        let city = location?.city ?? ""
        let country = location?.country ?? ""
        var services: [String] = []
        if accessSettings?.sshEnabled == true { services.append("SSH") }
        if accessSettings?.sambaEnabled == true { services.append("Samba") }
        if accessSettings?.webdavEnabled == true { services.append("WebDAV") }
        if accessSettings?.zfsEnabled == true { services.append("ZFS") }
        return StorageBox(
            id: id,
            name: name.nonEmpty ?? username.nonEmpty ?? "Storage Box",
            username: username ?? "",
            host: server ?? "",
            status: status.nonEmpty ?? "unknown",
            product: storageBoxType?.description.nonEmpty ?? storageBoxType?.name ?? "",
            location: !city.isEmpty && !country.isEmpty ? "\(city), \(country)" : (city.isEmpty ? location?.name ?? "" : city),
            quotaBytes: storageBoxType?.size ?? 0,
            usedBytes: stats?.size ?? 0,
            usedDataBytes: stats?.sizeData ?? 0,
            usedSnapshotBytes: stats?.sizeSnapshots ?? 0,
            services: services,
            deleteProtected: protection?.delete == true,
            reachableExternally: accessSettings?.reachableExternally == true,
            system: system ?? "",
            created: created ?? ""
        )
    }
}

/// Projects every server and hangs each volume off the server it is mounted
/// on. The server object only carries volume ids, and the sizes and device
/// paths are what anyone actually wants to see.
func joinVolumes(servers: [APIServer], volumes: [APIVolume]) -> [Server] {
    var byServer: [Int: [Volume]] = [:]
    for volume in volumes {
        guard let owner = volume.server else { continue }
        byServer[owner, default: []].append(volume.volume)
    }
    return servers.map { $0.server(volumes: byServer[$0.id] ?? []) }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
