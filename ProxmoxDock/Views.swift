import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case guests = "VMs & Containers"
    case storage = "Storage"
    case tasks = "Tasks"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .guests: return "shippingbox"
        case .storage: return "externaldrive"
        case .tasks: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(item == .tasks ? store.failedTasks.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                if let err = store.errorMessage {
                    ErrorBanner(message: err) { store.dismissError() }
                }
                if store.untrustedFingerprint != nil {
                    CertificateBanner()
                }
                if !store.isConfigured {
                    OnboardingView()
                } else {
                    switch selection ?? .overview {
                    case .overview: OverviewView()
                    case .guests: GuestsView()
                    case .storage: StorageView()
                    case .tasks: TasksView()
                    }
                }
                if !store.tracked.isEmpty { TrackedTasksBar() }
            }
            .navigationTitle(selection?.rawValue ?? "Proxmox")
            .navigationSubtitle(store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        store.manualRefresh(from: "toolbar")
                    } label: {
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .help("Refresh (⌘R)")
                    .disabled(store.isLoading)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

/// Shown when the server presents a certificate macOS doesn't trust and the user hasn't pinned.
struct CertificateBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("The server uses a certificate that macOS doesn't trust (usually Proxmox's self-signed one).")
                    .font(.callout)
                Text("Check the fingerprint in Settings before trusting it.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text("Review…") }
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

struct OnboardingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect to Proxmox VE", systemImage: "server.rack")
        } description: {
            Text("In the Proxmox web interface go to Datacenter → Permissions → API Tokens and add a token, then enter the server URL, token ID and secret in Settings.")
        } actions: {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Tasks started from the app, with their progress.
struct TrackedTasksBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.tracked) { t in
                HStack(spacing: 8) {
                    if !t.finished {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: t.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(t.succeeded ? .green : .red)
                    }
                    Text(t.title).font(.callout)
                    Text(t.finished ? (t.exitStatus ?? "") : "Running on \(t.node)…")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(.bar)
    }
}

// MARK: - Overview

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

/// Horizontal usage bar with label and value.
struct UsageBar: View {
    let title: String
    let fraction: Double
    let detail: String

    var color: Color { fraction >= 0.9 ? .red : (fraction >= 0.75 ? .orange : .accentColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color.gradient)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
            .frame(height: 6)
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    StatCard(title: "Nodes online", value: "\(store.onlineNodes.count)/\(store.nodes.count)", icon: "server.rack",
                             tint: store.onlineNodes.count == store.nodes.count ? .green : .red)
                    StatCard(title: "Running", value: "\(store.runningGuests.count)/\(store.guests.filter { !$0.template }.count)",
                             icon: "play.circle")
                    StatCard(title: "Problems", value: "\(store.problems.count)", icon: "exclamationmark.triangle",
                             tint: store.problems.isEmpty ? .green : .red)
                    StatCard(title: "Failed tasks (24 h)", value: "\(store.failedTasks.count)", icon: "xmark.octagon",
                             tint: store.failedTasks.isEmpty ? .green : .red)
                }

                if !store.problems.isEmpty {
                    Text("Problems").font(.title3.bold())
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.problems) { p in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: p.icon).foregroundStyle(.red).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title)
                                    if !p.detail.isEmpty { Text(p.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }

                if let ceph = store.ceph {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundStyle(ceph.status == "HEALTH_OK" ? .green : (ceph.status == "HEALTH_WARN" ? .orange : .red))
                        Text("Ceph \(ceph.status)").font(.headline)
                        Text(ceph.summaries.prefix(2).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Nodes").font(.title3.bold())
                    Spacer()
                    if let v = store.version {
                        Text("Proxmox VE \(v.version)\(store.cluster.map { " · cluster \($0.name)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(store.nodes) { NodeCard(node: $0) }
                }
            }
            .padding(20)
        }
    }
}

struct NodeCard: View {
    let node: PVENode
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let guests = store.guests.filter { $0.node == node.name && !$0.template }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(node.online ? .green : .red).frame(width: 10, height: 10)
                Text(node.name).font(.headline)
                Spacer()
                Text(node.online ? "Up \(Fmt.uptime(node.uptime))" : "Offline").font(.caption).foregroundStyle(.secondary)
                if node.online {
                    Button { openWindow(id: "performance", value: ResourceTarget.node(node.name)) } label: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    .buttonStyle(.borderless)
                    .help("Show \(node.name)'s performance")
                    Button { openWindow(id: "console", value: ResourceTarget.node(node.name)) } label: {
                        Image(systemName: "terminal")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(node.name)'s shell")
                }
            }
            if node.online {
                UsageBar(title: "CPU (\(Int(node.maxcpu)) cores)", fraction: node.cpu, detail: Fmt.percent(node.cpu))
                UsageBar(title: "Memory", fraction: node.maxmem > 0 ? node.mem / node.maxmem : 0,
                         detail: "\(Fmt.bytes(node.mem)) / \(Fmt.bytes(node.maxmem))")
                UsageBar(title: "Root disk", fraction: node.maxdisk > 0 ? node.disk / node.maxdisk : 0,
                         detail: "\(Fmt.bytes(node.disk)) / \(Fmt.bytes(node.maxdisk))")
            }
            Text("\(guests.filter(\.isRunning).count) of \(guests.count) VMs/CTs running")
                .font(.caption).foregroundStyle(.secondary)
            if node.online { NodeHealth(node: node.name) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

/// ZFS pools, SMART and available updates of one node.
struct NodeHealth: View {
    let node: String
    @EnvironmentObject var store: Store

    var body: some View {
        let pools = store.zfsPools[node] ?? []
        let disks = store.disks[node]
        let updates = store.updates[node]
        if !pools.isEmpty || disks != nil || updates != nil {
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                ForEach(pools) { p in
                    HStack(spacing: 6) {
                        Image(systemName: p.isHealthy ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                            .foregroundStyle(p.isHealthy ? .green : .red)
                        Text("ZFS \(p.name)")
                        Text(p.health).foregroundStyle(p.isHealthy ? Color.secondary : Color.red)
                        Spacer()
                        Text("\(Fmt.percent(p.fraction)) used").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let disks {
                    let failing = disks.filter(\.isFailing)
                    HStack(spacing: 6) {
                        Image(systemName: failing.isEmpty ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                            .foregroundStyle(failing.isEmpty ? .green : .red)
                        Text(failing.isEmpty ? "\(disks.count) disk(s), SMART OK"
                                             : "\(failing.count) of \(disks.count) disk(s) failing SMART")
                        Spacer()
                    }
                    .help(disks.map { "\($0.label): \($0.health ?? "no SMART data")\($0.wearout.map { ", wearout \($0)" } ?? "")" }.joined(separator: "\n"))
                }
                if let updates {
                    HStack(spacing: 6) {
                        Image(systemName: updates.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(updates.isEmpty ? .green : .blue)
                        Text(updates.isEmpty ? "Up to date" : "\(updates.count) update(s) available")
                        Spacer()
                    }
                    .help(updates.prefix(25).map { "\($0.package) \($0.oldVersion.map { "\($0) → " } ?? "")\($0.version)" }.joined(separator: "\n"))
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - VMs & Containers

struct GuestsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var filter = 0 // 0 all, 1 running, 2 stopped
    @State private var selection = Set<Guest.ID>()
    @State private var sortOrder = [KeyPathComparator(\Guest.vmid)]
    @State private var detail: Guest?
    @State private var pendingPower: (guest: Guest, action: ProxmoxAPI.PowerAction)?
    @State private var confirmPower = false

    private var filtered: [Guest] {
        store.guests.filter { g in
            (filter == 0 || (filter == 1) == g.isRunning) &&
            (search.isEmpty || g.displayName.localizedCaseInsensitiveContains(search) || String(g.vmid).contains(search)
                || g.node.localizedCaseInsensitiveContains(search) || g.tags.contains { $0.localizedCaseInsensitiveContains(search) }
                || (store.addresses[g.id]?.addresses.contains { $0.contains(search) } ?? false))
        }
        .sorted(using: sortOrder)
    }

    private func request(_ g: Guest, _ action: ProxmoxAPI.PowerAction) {
        if action == .start {
            Task { await store.power(g, action) }
        } else {
            pendingPower = (g, action)
            confirmPower = true
        }
    }

    var body: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.statusSort) { g in
                if store.isBusy(g) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: g.template ? "doc.on.doc" : (g.isRunning ? "play.circle.fill" : "stop.circle"))
                        .foregroundStyle(g.template ? Color.secondary : (g.isRunning ? Color.green : Color.secondary))
                        .help(g.template ? "Template" : g.status.capitalized)
                }
            }.width(22)
            TableColumn("ID", value: \.vmid) { g in Text(String(g.vmid)).monospacedDigit() }.width(min: 44, ideal: 54)
            TableColumn("Name", value: \.name) { g in
                HStack(spacing: 6) {
                    Text(g.displayName)
                    if let lock = g.lock { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange).help("Locked: \(lock)") }
                }
            }
            TableColumn("IP") { g in
                if g.isRunning, let a = store.addresses[g.id] {
                    Text(a.summary)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(a.state == .ok ? Color.primary : Color.secondary)
                        .help(a.help)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }.width(min: 90, ideal: 130)
            TableColumn("Type", value: \.kind.rawValue) { g in Text(g.template ? "\(g.kindLabel) template" : g.kindLabel) }
                .width(min: 40, ideal: 70)
            TableColumn("Node", value: \.node).width(min: 60, ideal: 90)
            TableColumn("CPU", value: \.cpuSort) { g in
                Text(g.isRunning ? "\(Fmt.percent(g.cpu)) of \(Int(g.maxcpu))" : "—").monospacedDigit()
            }.width(min: 60, ideal: 80)
            TableColumn("Memory", value: \.memSort) { g in
                Text(g.isRunning ? "\(Fmt.bytes(g.mem)) / \(Fmt.bytes(g.maxmem))" : Fmt.bytes(g.maxmem)).monospacedDigit()
            }.width(min: 110, ideal: 150)
            TableColumn("Uptime", value: \.uptimeSort) { g in Text(g.isRunning ? Fmt.uptime(g.uptime) : "—") }
                .width(min: 60, ideal: 80)
            TableColumn("Tags") { g in Text(g.tags.joined(separator: ", ")).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 100)
        }
        .contextMenu(forSelectionType: Guest.ID.self) { ids in
            if ids.count == 1, let g = store.guests.first(where: { ids.contains($0.id) }), !g.template {
                ForEach(ProxmoxAPI.PowerAction.allCases) { action in
                    Button { request(g, action) } label: { Label(action.title, systemImage: action.icon) }
                        .disabled((action == .start) == g.isRunning || store.isBusy(g))
                }
                Divider()
                Button { openWindow(id: "console", value: ResourceTarget.guest(g)) } label: {
                    Label("Open Console", systemImage: "terminal")
                }
                Button { openWindow(id: "performance", value: ResourceTarget.guest(g)) } label: {
                    Label("Show Performance", systemImage: "chart.xyaxis.line")
                }
                if let ips = store.addresses[g.id]?.addresses, g.isRunning, !ips.isEmpty {
                    Divider()
                    GuestConnectMenu(addresses: ips, sshUser: store.sshUser)
                }
                Button("Snapshots & Backup…") { detail = g }
            }
        } primaryAction: { ids in
            if ids.count == 1, let g = store.guests.first(where: { ids.contains($0.id) }), !g.template { detail = g }
        }
        .searchable(text: $search, prompt: "Name, ID, IP, node or tag")
        .task { await store.loadAddresses(api: store.api) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $filter) {
                    Text("All").tag(0)
                    Text("Running").tag(1)
                    Text("Stopped").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
        }
        .sheet(item: $detail) { g in GuestDetailView(guestID: g.id) }
        .confirmationDialog(
            pendingPower.map { "\($0.action.title) \($0.guest.displayName)?" } ?? "",
            isPresented: $confirmPower
        ) {
            if let p = pendingPower {
                Button(p.action.title, role: p.action == .stop ? .destructive : nil) {
                    Task { await store.power(p.guest, p.action) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let p = pendingPower { Text(PowerCopy.message(p.action, p.guest)) }
        }
        .overlay {
            if store.guests.isEmpty && !store.isLoading {
                ContentUnavailableView("No VMs or containers", systemImage: "shippingbox",
                                       description: Text("Or the API token can't see them: it needs VM.Audit."))
            }
        }
    }
}

enum PowerCopy {
    static func message(_ action: ProxmoxAPI.PowerAction, _ g: Guest) -> String {
        switch action {
        case .start: return "Starts \(g.displayName) on \(g.node)."
        case .shutdown: return "Asks the guest OS to shut down cleanly\(g.kind == .qemu ? " (needs ACPI or the QEMU guest agent)" : "")."
        case .reboot: return "Asks the guest OS to restart."
        case .stop: return "Stops \(g.displayName) immediately, like pulling the power cord. Unsaved data in the guest is lost."
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @EnvironmentObject var store: Store
    @State private var sortOrder = [KeyPathComparator(\PVEStorage.fractionSort, order: .reverse)]

    var body: some View {
        Table(store.storages.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("", value: \.fractionSort) { s in
                Image(systemName: s.available ? "externaldrive.fill" : "externaldrive.badge.xmark")
                    .foregroundStyle(s.available ? (s.fraction >= store.storageWarning ? Color.red : Color.secondary) : Color.red)
                    .help(s.available ? "Available" : "Not available")
            }.width(22)
            TableColumn("Storage", value: \.storage)
            TableColumn("Node", value: \.nodesLabel).width(min: 60, ideal: 100)
            TableColumn("Type", value: \.type).width(min: 50, ideal: 70)
            TableColumn("Usage", value: \.fractionSort) { s in
                UsageBar(title: "", fraction: s.fraction, detail: s.total > 0 ? Fmt.percent(s.fraction) : "—")
            }.width(min: 120, ideal: 180)
            TableColumn("Used / Total", value: \.totalSort) { s in
                Text(s.total > 0 ? "\(Fmt.bytes(s.used)) / \(Fmt.bytes(s.total))" : "—").monospacedDigit()
            }.width(min: 120, ideal: 150)
            TableColumn("Content") { s in Text(s.content.joined(separator: ", ")).foregroundStyle(.secondary) }
        }
        .overlay {
            if store.storages.isEmpty && !store.isLoading {
                ContentUnavailableView("No storage", systemImage: "externaldrive",
                                       description: Text("Or the API token can't see it: it needs Datastore.Audit."))
            }
        }
    }
}

// MARK: - Tasks

struct TasksView: View {
    @EnvironmentObject var store: Store
    @State private var failedOnly = false
    @State private var sortOrder = [KeyPathComparator(\PVETask.startSort, order: .reverse)]

    var body: some View {
        let list = store.tasks.filter { !failedOnly || $0.isFailed }.sorted(using: sortOrder)
        Table(list, sortOrder: $sortOrder) {
            TableColumn("", value: \.startSort) { t in
                if t.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: t.isFailed ? "xmark.octagon.fill" : (t.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle"))
                        .foregroundStyle(t.isFailed ? .red : (t.isWarning ? .orange : .green))
                }
            }.width(22)
            TableColumn("Started", value: \.startSort) { t in Text(Fmt.relative(t.startDate)).help(Fmt.dateTime(t.startDate)) }
                .width(min: 80, ideal: 100)
            TableColumn("Task", value: \.type) { t in Text(t.title) }
            TableColumn("Target", value: \.objectID) { t in Text(t.objectID.isEmpty ? "—" : store.guestName(t.objectID)) }
            TableColumn("Node", value: \.node).width(min: 60, ideal: 80)
            TableColumn("Duration") { t in Text(t.duration.map(Fmt.duration) ?? "—").monospacedDigit() }.width(min: 60, ideal: 80)
            TableColumn("User", value: \.user).width(min: 80, ideal: 110)
            TableColumn("Status") { t in
                Text(t.statusText).foregroundStyle(t.isFailed ? .red : .secondary).help(t.statusText)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle("Failed only", isOn: $failedOnly).toggleStyle(.checkbox)
            }
        }
        .overlay {
            if list.isEmpty && !store.isLoading {
                ContentUnavailableView(failedOnly ? "No failed tasks" : "No tasks in the last 24 hours",
                                       systemImage: failedOnly ? "checkmark.circle" : "list.bullet.rectangle")
            }
        }
    }
}
