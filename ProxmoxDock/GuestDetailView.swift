import SwiftUI

/// Power, snapshots and backup for one VM or container.
struct GuestDetailView: View {
    let guestID: String
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var snapshots: [PVESnapshot] = []
    @State private var loadingSnapshots = false
    @State private var snapshotError: String?
    @State private var showNewSnapshot = false
    @State private var pendingRollback: PVESnapshot?
    @State private var pendingDelete: PVESnapshot?
    @State private var confirmRollback = false
    @State private var confirmDelete = false
    @State private var pendingPower: ProxmoxAPI.PowerAction?
    @State private var confirmPower = false

    @State private var backupStorages: [NodeStorage] = []
    @State private var backupStorage = ""
    @State private var backupMode = ProxmoxAPI.BackupMode.snapshot
    @State private var backupNotes = "{{guestname}} – manual backup from ProxmoxDock"
    @State private var confirmBackup = false

    private var guest: Guest? { store.guests.first { $0.id == guestID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let g = guest {
                header(g)
                Divider()
                snapshotSection(g)
                Divider()
                backupSection(g)
            } else {
                Text("This VM or container is no longer available.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await loadAll() }
        .sheet(isPresented: $showNewSnapshot) {
            if let g = guest {
                NewSnapshotSheet(guest: g) { name, description, ram in
                    Task {
                        await store.run("Snapshot \(name) of \(g.displayName)", node: g.node, guestID: g.id,
                                        privilege: "VM.Snapshot on /vms/\(g.vmid)") {
                            try await $0.createSnapshot(g, name: name, description: description, includeRAM: ram)
                        }
                        await loadSnapshots()
                    }
                }
            }
        }
    }

    // MARK: Header and power

    @ViewBuilder
    private func header(_ g: Guest) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: g.kind == .qemu ? "desktopcomputer" : "shippingbox.fill").foregroundStyle(.secondary)
                    Text(g.displayName).font(.title2.bold())
                    Text("\(g.kindLabel) \(g.vmid)").foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(g.isRunning ? .green : .secondary).frame(width: 8, height: 8)
                    Text(g.isRunning ? "Running for \(Fmt.uptime(g.uptime))" : g.status.capitalized)
                    Text("· on \(g.node)").foregroundStyle(.secondary)
                    if let lock = g.lock { Text("· locked (\(lock))").foregroundStyle(.orange) }
                }
                .font(.callout)
                addressRow(g)
            }
            Spacer()
            if store.isBusy(g) { ProgressView().controlSize(.small) }
        }
        HStack {
            ForEach(ProxmoxAPI.PowerAction.allCases) { action in
                Button {
                    if action == .start {
                        Task { await store.power(g, .start) }
                    } else {
                        pendingPower = action
                        confirmPower = true
                    }
                } label: { Label(action.title, systemImage: action.icon) }
                .disabled((action == .start) == g.isRunning || store.isBusy(g))
            }
            Spacer()
            Button { openWindow(id: "console", value: ConsoleTarget.guest(g)) } label: {
                Label("Console", systemImage: "terminal")
            }
        }
        .confirmationDialog(pendingPower.map { "\($0.title) \(g.displayName)?" } ?? "", isPresented: $confirmPower, presenting: pendingPower) { action in
            Button(action.title, role: action == .stop ? .destructive : nil) {
                Task { await store.power(g, action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(PowerCopy.message(action, g))
        }
    }

    @ViewBuilder
    private func addressRow(_ g: Guest) -> some View {
        if g.isRunning, let a = store.addresses[g.id] {
            if a.addresses.isEmpty {
                Text(a.state == .ok ? "No IP address reported" : a.summary)
                    .font(.caption).foregroundStyle(.secondary).help(a.help)
            } else {
                HStack(spacing: 6) {
                    ForEach(a.addresses.prefix(4), id: \.self) { ip in
                        Menu {
                            GuestConnectMenu(addresses: [ip], sshUser: store.sshUser)
                        } label: {
                            Text(ip).font(.system(.caption, design: .monospaced))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Copy, SSH or open \(ip)")
                    }
                    if a.addresses.count > 4 { Text("+\(a.addresses.count - 4)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    // MARK: Snapshots

    @ViewBuilder
    private func snapshotSection(_ g: Guest) -> some View {
        HStack {
            Text("Snapshots").font(.headline)
            if loadingSnapshots { ProgressView().controlSize(.small) }
            Spacer()
            Button { showNewSnapshot = true } label: { Label("Take Snapshot…", systemImage: "camera") }
                .disabled(store.isBusy(g))
        }
        if let snapshotError {
            Text(snapshotError).font(.caption).foregroundStyle(.red)
        }
        let list = snapshots.filter { !$0.isCurrent }.sorted { ($0.snaptime ?? 0) > ($1.snaptime ?? 0) }
        if list.isEmpty && !loadingSnapshots && snapshotError == nil {
            Text("No snapshots.").font(.callout).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.vmstate ? "memorychip" : "camera.fill")
                                .foregroundStyle(.secondary).frame(width: 18)
                                .help(s.vmstate ? "Includes RAM" : "Disk only")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.callout.weight(.medium))
                                Text([s.snaptime.map { Fmt.dateTime($0.asDate) }, s.description.isEmpty ? nil : s.description]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Roll Back…") {
                                pendingRollback = s
                                confirmRollback = true
                            }
                            .disabled(store.isBusy(g))
                            Button(role: .destructive) {
                                pendingDelete = s
                                confirmDelete = true
                            } label: { Image(systemName: "trash") }
                            .help("Delete snapshot")
                            .disabled(store.isBusy(g))
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        EmptyView()
            .confirmationDialog("Roll back \(g.displayName) to “\(pendingRollback?.name ?? "")”?", isPresented: $confirmRollback, presenting: pendingRollback) { s in
                ForEach([true, false], id: \.self) { start in
                    Button(start ? "Roll Back and Start" : "Roll Back", role: .destructive) {
                        Task {
                            await store.run("Roll back \(g.displayName) to \(s.name)", node: g.node, guestID: g.id,
                                            privilege: "VM.Snapshot.Rollback on /vms/\(g.vmid)") {
                                try await $0.rollback(g, snapshot: s.name, start: start)
                            }
                            await loadSnapshots()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("All changes made since this snapshot are lost. “Roll Back and Start” starts the guest afterwards; otherwise it stays stopped.")
            }
            .confirmationDialog("Delete snapshot “\(pendingDelete?.name ?? "")”?", isPresented: $confirmDelete, presenting: pendingDelete) { s in
                Button("Delete", role: .destructive) {
                    Task {
                        await store.run("Delete snapshot \(s.name) of \(g.displayName)", node: g.node, guestID: g.id,
                                        privilege: "VM.Snapshot on /vms/\(g.vmid)") {
                            try await $0.deleteSnapshot(g, snapshot: s.name)
                        }
                        await loadSnapshots()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The snapshot is removed from Proxmox. This can't be undone.")
            }
    }

    // MARK: Backup

    @ViewBuilder
    private func backupSection(_ g: Guest) -> some View {
        Text("Backup").font(.headline)
        if backupStorages.isEmpty {
            Text("No storage with backup content is available on \(g.node) (or the token lacks Datastore.Audit).")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Storage").gridColumnAlignment(.trailing)
                    Picker("", selection: $backupStorage) {
                        ForEach(backupStorages) { s in
                            Text(s.avail.map { "\(s.storage) (\(Fmt.bytes($0)) free)" } ?? s.storage).tag(s.storage)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Mode")
                    Picker("", selection: $backupMode) {
                        ForEach(ProxmoxAPI.BackupMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Notes")
                    TextField("", text: $backupNotes)
                }
            }
            HStack {
                Text("Compressed with zstd. Old backups may be pruned by the storage's retention settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { confirmBackup = true } label: { Label("Back Up Now", systemImage: "externaldrive.badge.plus") }
                    .disabled(backupStorage.isEmpty || store.isBusy(g))
            }
            .confirmationDialog("Back up \(g.displayName) to \(backupStorage)?", isPresented: $confirmBackup) {
                Button("Back Up") {
                    let storage = backupStorage, mode = backupMode, notes = backupNotes
                    Task {
                        await store.run("Backup of \(g.displayName)", node: g.node, guestID: g.id,
                                        privilege: "VM.Backup on /vms/\(g.vmid) and Datastore.AllocateSpace on /storage/\(storage)") {
                            try await $0.backup(g, storage: storage, mode: mode, notes: notes)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(backupMode == .snapshot ? "The guest keeps running during the backup."
                     : backupMode == .suspend ? "The guest is paused briefly during the backup."
                     : "The guest is stopped during the backup and started again afterwards.")
            }
        }
    }

    // MARK: Loading

    private func loadAll() async {
        if let g = guest, g.isRunning { await store.refreshAddresses(of: g) }
        await loadSnapshots()
        guard let g = guest else { return }
        let storages = (try? await store.api.backupStorages(node: g.node)) ?? []
        backupStorages = storages.filter { $0.active && $0.enabled }
        if !backupStorages.contains(where: { $0.storage == backupStorage }) {
            backupStorage = backupStorages.max { ($0.avail ?? 0) < ($1.avail ?? 0) }?.storage ?? ""
        }
    }

    private func loadSnapshots() async {
        guard let g = guest else { return }
        loadingSnapshots = true
        defer { loadingSnapshots = false }
        do {
            snapshots = try await store.api.snapshots(g)
            snapshotError = nil
        } catch {
            snapshotError = "Could not load snapshots: \(error.localizedDescription)"
        }
    }
}

struct NewSnapshotSheet: View {
    let guest: Guest
    let onCreate: (String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "snap_\(Date().formatted(.iso8601.year().month().day()).replacingOccurrences(of: "-", with: ""))"
    @State private var description = ""
    @State private var includeRAM = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Snapshot of \(guest.displayName)").font(.headline)
            TextField("Name", text: $name)
            if !name.isEmpty && !PVESnapshot.isValidName(name) {
                Text("Start with a letter; use letters, digits, “_” or “-”; at most 40 characters.")
                    .font(.caption).foregroundStyle(.red)
            }
            TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(2...4)
            if guest.kind == .qemu {
                Toggle("Include RAM", isOn: $includeRAM)
                    .disabled(!guest.isRunning)
                    .help("Saves the running state so a rollback resumes where it was. Takes longer and uses more space.")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Take Snapshot") {
                    onCreate(name, description, includeRAM && guest.isRunning)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!PVESnapshot.isValidName(name))
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
