import RackbarCore
import SwiftUI

/// Filled for running, hollow for off, breathing while it changes, red when
/// something is wrong. Filled against hollow is a shape, not a shade, so it
/// reads in every appearance.
struct StatusDot: View {
    let tone: Tone
    var status = ""

    var body: some View {
        Image(systemName: tone == .live || tone == .bad ? "circle.fill" : "circle")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: tone == .busy)
            .frame(width: 12)
            .help(status)
            .accessibilityLabel(status)
    }

    private var color: Color {
        switch tone {
        case .live: .green
        case .off: .secondary
        case .busy: .orange
        case .bad: .red
        }
    }
}

/// A row: click copies the address, the menu has the rest.
private struct Row<Content: View, Menu: View>: View {
    let copyValue: String?
    let help: String
    @ViewBuilder let content: Content
    @ViewBuilder let menu: Menu
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let copyValue { model.copy(copyValue) }
            } label: {
                HStack(spacing: 10) {
                    content
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)

            SwiftUI.Menu {
                menu
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .help("Copy…")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6))
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }
}

struct ServerRow: View {
    let server: Server
    let namespace: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Row(copyValue: server.ipv4,
            help: server.ipv4.map { "Click to copy \($0)" } ?? "No public IPv4") {
            StatusDot(tone: server.tone, status: server.locked ? "\(server.status), locked" : server.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(server.name).fontWeight(.medium)
                    if server.locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if server.status != "running" {
                        Text(server.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text([server.ipv4 ?? "no IPv4", server.typeName, server.location]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } menu: {
            if let ipv4 = server.ipv4 {
                Button("IPv4  \(ipv4)") { model.copy(ipv4) }
            }
            Button("Name  \(server.name)") { model.copy(server.name) }
            if let ipv6 = server.ipv6 {
                Button("IPv6  \(ipv6)") { model.copy(ipv6) }
            }
            if let privateIP = server.privateIP {
                Button("Private  \(privateIP)") { model.copy(privateIP) }
            }
            let alias = sshAlias(namespace: namespace, server: server.name)
            if server.ipv4 != nil, alias != server.name {
                Divider()
                Button("ssh \(alias)") { model.copy(alias) }
            }
        }
    }
}

struct StorageBoxRow: View {
    let box: StorageBox
    @Environment(AppModel.self) private var model

    var body: some View {
        Row(copyValue: box.host.isEmpty ? nil : box.host, help: "Click to copy \(box.host)") {
            StatusDot(tone: box.tone, status: box.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive").font(.caption).foregroundStyle(.secondary)
                    Text(box.name).fontWeight(.medium)
                }
                Text([box.product, box.location, box.services.joined(separator: " · ")]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if box.quotaBytes > 0 {
                    ProgressView(value: box.fill)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(box.tone == .live ? Color.accentColor : (box.tone == .busy ? Color.orange : Color.red))
                        .help("\(box.usedBytes.formatted(.byteCount(style: .binary))) of \(box.quotaBytes.formatted(.byteCount(style: .binary)))")
                }
            }
        } menu: {
            if !box.host.isEmpty {
                Button("Host  \(box.host)") { model.copy(box.host) }
            }
            if !box.username.isEmpty {
                Button("User  \(box.username)") { model.copy(box.username) }
            }
            if let target = box.sshTarget {
                Divider()
                Button("ssh \(target)") { model.copy(target) }
            }
        }
    }
}

/// Says what the last sync did, or why it did not.
struct SSHStatusLine: View {
    let status: SSHStatus
    var compact = false

    var body: some View {
        switch status {
        case .off:
            if !compact { Label("Off", systemImage: "circle.dashed").foregroundStyle(.secondary) }
        case .demo:
            Label("Demo data — nothing written", systemImage: "eye").foregroundStyle(.secondary)
        case .needsFolder:
            Label("ssh: choose a folder in Settings", systemImage: "folder.badge.questionmark")
                .foregroundStyle(.orange)
        case .waiting:
            Label("ssh: waiting for the first refresh", systemImage: "clock").foregroundStyle(.secondary)
        case .incomplete(let labels):
            Label("ssh: \(labels.joined(separator: ", ")) did not load — nothing written",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .synced(let hosts, let at, let changed):
            Label(compact ? "ssh: \(hosts) hosts" : "\(hosts) hosts · \(changed ? "written" : "unchanged") \(at.formatted(date: .omitted, time: .shortened))",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
