import AppKit
import RackbarCore
import SwiftUI

/// The window under the menu bar icon: every server in every project.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.accounts.isEmpty && !model.demoMode {
                EmptyFleet(showSettings: showSettings)
            } else {
                TextField("Search", text: $query, prompt: Text("Search servers, addresses, labels"))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                list
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Rackbar").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isRefreshing)
            }
            .disabled(model.isRefreshing)
            .help("Refresh now")
            Menu {
                Button("Settings…", action: showSettings)
                Divider()
                Button("Quit Rackbar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(visibleProjects) { project in
                    Section {
                        if let error = project.error {
                            Label(project.isStale ? "\(error) — showing the last list" : error,
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4)
                        }
                        ForEach(project.servers.filter { $0.matches(query) }) { server in
                            ServerRow(server: server, namespace: project.namespace)
                        }
                        ForEach(project.storageBoxes.filter { $0.matches(query) }) { box in
                            StorageBoxRow(box: box)
                        }
                    } header: {
                        ProjectHeader(project: project)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(height: listHeight)
    }

    private var footer: some View {
        HStack {
            if let copied = model.lastCopied {
                Label("Copied \(copied)", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else {
                SSHStatusLine(status: model.sshStatus, compact: true)
            }
            Spacer()
            if let last = model.lastRefresh {
                Text("Updated \(last, style: .relative) ago")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// While a search is running, a project with nothing to show is noise.
    /// A project that failed is not: a broken token must not disappear
    /// exactly when you are looking for something.
    private var visibleProjects: [Project] {
        model.projects.filter { project in
            query.isEmpty || !project.isOK
                || project.servers.contains { $0.matches(query) }
                || project.storageBoxes.contains { $0.matches(query) }
        }
    }

    /// Tall enough for the rows, never taller than a screen wants.
    private var listHeight: CGFloat {
        let rows = visibleProjects.reduce(0) { total, project in
            total + project.servers.filter { $0.matches(query) }.count
                + project.storageBoxes.filter { $0.matches(query) }.count
                + (project.error == nil ? 0 : 1)
        }
        return min(520, max(80, CGFloat(rows) * 44 + CGFloat(visibleProjects.count) * 28 + 6))
    }

    private var summary: String {
        if model.demoMode { return "Demo data" }
        var parts = ["\(model.serverCount) \(model.serverCount == 1 ? "server" : "servers")",
                     "\(model.projects.count) \(model.projects.count == 1 ? "project" : "projects")"]
        if model.failedCount > 0 { parts.append("\(model.failedCount) failed") }
        return parts.joined(separator: " · ")
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

private struct ProjectHeader: View {
    let project: Project

    var body: some View {
        HStack(spacing: 6) {
            Text(project.label.uppercased())
                .font(.caption.weight(.semibold))
            Text("\(project.servers.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("ssh \(project.namespace)/…")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct EmptyFleet: View {
    @Environment(AppModel.self) private var model
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Hetzner Cloud projects yet")
                .font(.headline)
            Text("Add a read-only API token for each project you want to see. Rackbar lists, copies and keeps your ssh config in step — it never powers anything on or off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add a Project…", action: showSettings)
                .buttonStyle(.borderedProminent)
            Button("Look around with demo data") { model.demoMode = true }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(24)
    }
}
