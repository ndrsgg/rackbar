import AppKit
import RackbarCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Projects", systemImage: "server.rack") { ProjectsSettings() }
            Tab("SSH", systemImage: "terminal") { SSHSettings() }
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
        }
        .frame(width: 620, height: 560)
        // A menu bar app has no Dock icon, and a window of one does not come
        // to the front or show up in ⌘-Tab. For as long as this window is
        // open, Rackbar is an ordinary app.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Projects

private struct ProjectsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var adding: AddTarget?
    @State private var removing: Account?

    var body: some View {
        Form {
            Section {
                if model.accounts.isEmpty {
                    Text("No projects yet.").foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { account in
                    AccountRow(account: account, project: model.project(labelled: account.label),
                               onAdd: { adding = AddTarget(label: account.label) },
                               onRemove: { removing = account })
                }
                Button("Add Project Token…") { adding = AddTarget(label: "") }
            } header: {
                Text("Projects")
            } footer: {
                Text("""
                    One read-only API token per Hetzner Cloud project. Several tokens under one label \
                    share one heading and one ssh namespace — handy when a customer's servers are spread \
                    over several Hetzner projects.
                    """)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $adding) { target in
            AddTokenSheet(label: target.label)
        }
        .confirmationDialog("Remove “\(removing?.label ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button(account.keys.count == 1 ? "Remove Token" : "Remove \(account.keys.count) Tokens",
                   role: .destructive) {
                model.remove(label: account.label)
            }
        } message: { _ in
            Text("The tokens are deleted from the Keychain, and the label's hosts leave the ssh config with the next sync.")
        }
    }
}

private struct AddTarget: Identifiable {
    let id = UUID()
    var label: String
}

private struct AccountRow: View {
    let account: Account
    let project: Project?
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label).font(.headline)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = project?.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button(action: onAdd) { Image(systemName: "plus") }
                .help("Add another token to “\(account.label)”")
            Button(action: onRemove) { Image(systemName: "trash") }
                .help("Remove “\(account.label)” and its tokens")
        }
        .buttonStyle(.borderless)
    }

    private var details: String {
        var parts = ["ssh \(account.namespace)/…"]
        if let project { parts.append("\(project.servers.count) servers") }
        if account.keys.count > 1 { parts.append("\(account.keys.count) tokens") }
        return parts.joined(separator: " · ")
    }
}

private struct AddTokenSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var label: String
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Project Token").font(.title3.bold())
            Form {
                TextField("Label", text: $label, prompt: Text("production"))
                SecureField("API token", text: $token)
            }
            Text(labelHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Create the token in the Hetzner Cloud Console under **Security → API tokens → Generate**, with **Read** permission. Rackbar only ever reads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Link("Open Hetzner Console", destination: URL(string: "https://console.hetzner.cloud/projects")!)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || label.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var labelHint: String {
        let name = label.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "The label is the heading in the list and the namespace in ssh." }
        if model.accounts.account(labelled: name) != nil {
            return "Adds another token to “\(name)”: its servers join the same list and ssh \(sshNamespace(for: name))/…"
        }
        return "Servers will be reachable as ssh \(sshNamespace(for: name))/<server>."
    }

    private func add() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.addToken(token, label: label)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - SSH

private struct SSHSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Keep an ssh config for every server", isOn: $model.sshSyncEnabled)
            } footer: {
                Text("Every server with a public IPv4 becomes `ssh <label>/<server>` — with tab completion, and in scp, rsync, mosh and everything else that reads ssh's config.")
                    .foregroundStyle(.secondary)
            }

            Section("1 · A folder for Rackbar") {
                LabeledContent("Folder") {
                    Text(model.sshFolder.url?.path(percentEncoded: false) ?? "None chosen")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if let problem = model.sshFolder.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                HStack {
                    Button(model.sshFolder.url == nil ? "Choose Folder…" : "Change Folder…") {
                        model.sshFolder.choose()
                        model.syncSSH()
                    }
                    if model.sshFolder.url != nil {
                        Button("Forget") {
                            model.sshFolder.forget()
                            model.syncSSH()
                        }
                    }
                }
                Text("Create a folder of its own inside ~/.ssh — ~/.ssh/hcloud, say — and choose it. Rackbar can only see that folder: never your keys, never your own config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let folder = model.sshFolder.url {
                Section("2 · Include it from ~/.ssh/config, once") {
                    CopyableCode(SSHConfigFile.includeDirective(folder: folder))
                    Text("These two lines go at the end of ~/.ssh/config, so your own Host blocks above them win. Or paste this into a terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CopyableCode(SSHConfigFile.appendCommand(folder: folder))
                }
            }

            Section("3 · Tab completion") {
                Text("zsh completes ssh hosts only with its completion system on. If `ssh <label>/` and Tab offers nothing, add this to ~/.zshrc — before plugins such as zsh-syntax-highlighting:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CopyableCode("autoload -Uz compinit && compinit")
                if let example = Fleet.sshHosts(model.projects).first {
                    Text("To check that ssh resolves an alias:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CopyableCode("ssh -G \(example.alias) | grep -E '^(hostname|user) '")
                }
            }

            Section("Entries") {
                TextField("User", text: $model.sshUser, prompt: Text("root"))
                TextField("Identity file", text: $model.sshIdentityFile, prompt: Text("optional, e.g. ~/.ssh/id_ed25519"))
                Text("Anything that differs per project belongs in ~/.ssh/config above the Include line — `Host acme/*` with its own User, ProxyJump and so on. ssh takes the first value it finds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack {
                    SSHStatusLine(status: model.sshStatus)
                    Spacer()
                    Button("Sync Now") { model.syncSSH() }
                        .disabled(!model.sshSyncEnabled)
                }
                DisclosureGroup("Preview") {
                    ScrollView {
                        Text(model.sshPreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A line of code with a button that copies it.
private struct CopyableCode: View {
    @Environment(AppModel.self) private var model
    let code: String

    init(_ code: String) {
        self.code = code
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(code)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.copy(code)
            } label: {
                Image(systemName: model.lastCopied == code ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Refresh every", selection: $model.refreshInterval) {
                    Text("Minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("Hour").tag(3600)
                }
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("A refresh costs three requests per token. Opening the menu does not fetch again unless the list is older than this.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show demo data", isOn: $model.demoMode)
            } footer: {
                Text("An invented fleet for a first look and for screenshots. Your tokens and your ssh config are left alone.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link("rackbar.app", destination: URL(string: "https://rackbar.app")!)
                Link("Source code", destination: URL(string: "https://github.com/ndrsgg/rackbar")!)
                Text("Rackbar is not affiliated with Hetzner Online GmbH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            openAtLogin = on
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }
}
