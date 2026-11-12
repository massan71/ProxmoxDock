import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var urlDraft = ""
    @State private var tokenIDDraft = ""
    @State private var secretDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true
    @AppStorage(SettingsKey.showDockIcon) private var showDockIcon = true
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Proxmox VE Server") {
                TextField("Server URL", text: $urlDraft, prompt: Text("https://pve.lan:8006"))
                Text("Port 8006 is added if missing. Only https:// is accepted.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("API token ID", text: $tokenIDDraft, prompt: Text("user@pam!proxmoxdock"))
                SecureField("Secret", text: $secretDraft)
                Text("Datacenter → Permissions → API Tokens → Add. Viewing needs the PVEAuditor role; power actions need VM.PowerMgmt, snapshots VM.Snapshot (and VM.Snapshot.Rollback), backups VM.Backup and Datastore.AllocateSpace. The secret is stored in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save and Test") {
                        store.baseURL = ProxmoxAPI.normalizedBase(urlDraft)
                        urlDraft = store.baseURL
                        store.tokenID = tokenIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        test()
                    }
                    .buttonStyle(.borderedProminent)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let result = testResult { Text(result).font(.callout).textSelection(.enabled) }
            }

            Section("Certificate") {
                if let fp = store.untrustedFingerprint {
                    Text("The server presented a certificate that macOS doesn't trust. Compare this SHA-256 fingerprint with the one in the Proxmox web interface (node → System → Certificates, pve-ssl.pem) before trusting it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Trust This Certificate") {
                            store.trustPresentedCertificate()
                            test()
                        }
                    }
                } else if let pinned = store.pinnedFingerprint {
                    Text("Trusted certificate (SHA-256):").font(.caption).foregroundStyle(.secondary)
                    Text(pinned).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Text("If the server's certificate changes, you'll be asked to check the new one.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget") { store.pinnedFingerprint = nil }
                    }
                } else {
                    Text("Certificates trusted by macOS are accepted. For a self-signed certificate you'll be asked to check its fingerprint after Save and Test.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Notify about failed tasks and offline nodes", isOn: $store.notify)
                Picker("Warn when storage is fuller than", selection: $store.storageWarning) {
                    ForEach([0.8, 0.85, 0.9, 0.95], id: \.self) { Text(Fmt.percent($0)).tag($0) }
                }
                Text("The Dock badge counts problems: offline nodes, lost quorum, failed tasks in the last 24 hours and storage above this level.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu Bar and Dock") {
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Toggle("Show problem count next to the icon", isOn: $store.menuBarShowsCount)
                    .disabled(!showMenuBar)
                Toggle("Show icon in the Dock", isOn: $showDockIcon)
                    .disabled(!showMenuBar)
                Text(showMenuBar ? "Turn this off to use ProxmoxDock only from the menu bar."
                                 : "The Dock icon can only be hidden while the menu bar icon is shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: $openAtLogin)
                if loginNeedsApproval {
                    HStack {
                        Text("macOS needs your approval in Login Items.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: showMenuBar) { _, visible in
            if !visible && !showDockIcon { showDockIcon = true }
        }
        .onChange(of: showDockIcon) { _, visible in DockIcon.apply(visible) }
        .onChange(of: openAtLogin) { _, enabled in
            guard enabled != LoginItem.isEnabled else { return }
            do {
                try LoginItem.set(enabled)
                loginError = nil
            } catch {
                loginError = "Could not change Open at login: \(error.localizedDescription)"
                openAtLogin = LoginItem.isEnabled
            }
            loginNeedsApproval = LoginItem.needsApproval
        }
        .frame(width: 540)
        .padding(.vertical, 8)
        .onAppear {
            urlDraft = store.baseURL
            tokenIDDraft = store.tokenID
            secretDraft = store.secret
            openAtLogin = LoginItem.isEnabled
            loginNeedsApproval = LoginItem.needsApproval
        }
    }

    private func test() {
        testing = true
        Task {
            testResult = await store.testConnection()
            testing = false
            if store.untrustedFingerprint == nil { await store.refresh() }
        }
    }
}
