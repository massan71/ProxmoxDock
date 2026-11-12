import AppKit
import Foundation
import Network
import OSLog
import UserNotifications

private let log = Logger(subsystem: "local.proxmoxdock.app", category: "refresh")

enum SettingsKey {
    static let showMenuBar = "showMenuBar"
    static let showDockIcon = "showDockIcon"
}

/// Something that needs attention; the Dock badge shows how many there are.
struct Problem: Identifiable, Hashable {
    enum Kind { case nodeOffline, quorum, failedTask, storageFull }
    var kind: Kind
    var title: String
    var detail: String
    var id: String
    var icon: String {
        switch kind {
        case .nodeOffline: return "server.rack"
        case .quorum: return "exclamationmark.triangle.fill"
        case .failedTask: return "xmark.octagon.fill"
        case .storageFull: return "externaldrive.fill.badge.exclamationmark"
        }
    }
}

/// A task started from the app, followed until it finishes.
struct TrackedTask: Identifiable, Hashable {
    var upid: String
    var node: String
    var title: String
    var guestID: String?
    var started = Date()
    var finished = false
    var exitStatus: String?
    var id: String { upid }
    var succeeded: Bool { exitStatus == "OK" || exitStatus?.hasPrefix("WARNINGS") == true }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // Settings
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var tokenID: String { didSet { UserDefaults.standard.set(tokenID, forKey: "tokenID") } }
    @Published var secret: String { didSet { Keychain.save(secret) } }
    @Published var pinnedFingerprint: String? {
        didSet {
            UserDefaults.standard.set(pinnedFingerprint, forKey: "pinnedFingerprint")
            CertificateTrust.shared.pinned = pinnedFingerprint
        }
    }
    @Published var refreshMinutes: Int { didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); restartTimer() } }
    @Published var notify: Bool { didSet { UserDefaults.standard.set(notify, forKey: "notify"); if notify { requestNotificationPermission() } } }
    @Published var storageWarning: Double { didSet { UserDefaults.standard.set(storageWarning, forKey: "storageWarning"); updateDock() } }
    @Published var menuBarShowsCount: Bool { didSet { UserDefaults.standard.set(menuBarShowsCount, forKey: "menuBarShowsCount") } }

    // Data
    @Published var nodes: [PVENode] = []
    @Published var guests: [Guest] = []
    @Published var storages: [PVEStorage] = []
    @Published var tasks: [PVETask] = []
    @Published var cluster: ClusterStatusEntry?
    @Published var version: PVEVersion?

    // State
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    /// Fingerprint of a certificate the user hasn't trusted yet
    @Published var untrustedFingerprint: String?
    @Published var tracked: [TrackedTask] = []

    private var timerTask: Task<Void, Never>?
    private var refreshRequested = false
    private var pathMonitor: NWPathMonitor?
    private var isOffline = false
    private var wakeObserver: NSObjectProtocol?
    private var knownFailedTasks: Set<String>?
    private var knownOfflineNodes: Set<String>?

    var api: ProxmoxAPI { ProxmoxAPI(baseURL: baseURL, tokenID: tokenID, secret: secret) }
    var isConfigured: Bool { api.isConfigured }

    private init() {
        let d = UserDefaults.standard
        baseURL = d.string(forKey: "baseURL") ?? ""
        tokenID = d.string(forKey: "tokenID") ?? ""
        secret = Keychain.load()
        pinnedFingerprint = d.string(forKey: "pinnedFingerprint")
        refreshMinutes = d.object(forKey: "refreshMinutes") as? Int ?? 1
        notify = d.object(forKey: "notify") as? Bool ?? true
        storageWarning = d.object(forKey: "storageWarning") as? Double ?? 0.9
        menuBarShowsCount = d.object(forKey: "menuBarShowsCount") as? Bool ?? true
        CertificateTrust.shared.pinned = pinnedFingerprint
    }

    // MARK: Derived

    var runningGuests: [Guest] { guests.filter { $0.isRunning && !$0.template } }
    var onlineNodes: [PVENode] { nodes.filter(\.online) }
    var failedTasks: [PVETask] { tasks.filter(\.isFailed) }

    var problems: [Problem] {
        var out: [Problem] = []
        for n in nodes where !n.online {
            out.append(Problem(kind: .nodeOffline, title: "Node \(n.name) is offline", detail: "", id: "node-\(n.name)"))
        }
        if let cluster, cluster.type == "cluster", cluster.quorate == false {
            out.append(Problem(kind: .quorum, title: "Cluster \(cluster.name) has no quorum", detail: "", id: "quorum"))
        }
        for t in failedTasks {
            out.append(Problem(kind: .failedTask, title: "\(t.title) failed\(t.objectID.isEmpty ? "" : " (\(guestName(t.objectID)))")",
                               detail: "\(t.node) · \(Fmt.relative(t.startDate)) · \(t.status ?? "")", id: "task-\(t.upid)"))
        }
        for s in storages where s.available && s.total > 0 && s.fraction >= storageWarning {
            out.append(Problem(kind: .storageFull, title: "Storage \(s.storage) is \(Fmt.percent(s.fraction)) full",
                               detail: "\(s.nodesLabel) · \(Fmt.bytes(s.total - s.used)) free", id: "storage-\(s.id)"))
        }
        return out
    }

    /// "web (101)" for a VMID that belongs to a known guest.
    func guestName(_ vmid: String) -> String {
        guard let id = Int(vmid), let g = guests.first(where: { $0.vmid == id }) else { return vmid }
        return "\(g.displayName) (\(id))"
    }

    // MARK: Refresh loop

    func start() {
        if notify { requestNotificationPermission() }
        observeWakeAndNetwork()
        restartTimer()
    }

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                // Own task, so restarting the timer never cancels requests in flight
                await Task { @MainActor [weak self] in await self?.refresh() }.value
                let minutes = max(1, self?.refreshMinutes ?? 1)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    private func observeWakeAndNetwork() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            log.notice("Mac woke from sleep: refreshing in 5 s")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.restartTimer()
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "ProxmoxDock.network"))
        pathMonitor = monitor
    }

    private func networkChanged(online: Bool) {
        let cameBack = online && isOffline
        isOffline = !online
        if cameBack {
            log.notice("Network is back: refreshing")
            restartTimer()
        }
    }

    func manualRefresh(from source: String) {
        log.notice("Manual refresh from \(source, privacy: .public)")
        Task { await refresh() }
    }

    /// Refreshes everything; a refresh asked for while one runs is queued, never dropped.
    func refresh() async {
        guard isConfigured else {
            errorMessage = APIError.notConfigured.errorDescription
            updateDock()
            return
        }
        if isLoading {
            refreshRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshRequested = false
            log.notice("Refresh started")
            await loadAll()
            log.notice("Refresh finished")
        } while refreshRequested
    }

    private func loadAll() async {
        let api = self.api
        async let res = api.resources()
        async let status = api.clusterStatus()
        async let ver = api.version()

        var errors: [String] = []
        do {
            let resources = try await res
            nodes = resources.compactMap(PVENode.init).sorted { $0.name < $1.name }
            guests = resources.compactMap(Guest.init).sorted { $0.vmid < $1.vmid }
            storages = PVEStorage.from(resources)
            untrustedFingerprint = nil
        } catch {
            errors.append(describe(error))
        }
        // Needs Sys.Audit on "/"; optional
        if let entries = try? await status {
            cluster = entries.first { $0.type == "cluster" }
            let online = Dictionary(entries.filter { $0.type == "node" }.map { ($0.name, $0.online ?? true) }, uniquingKeysWith: { a, _ in a })
            for i in nodes.indices { if let o = online[nodes[i].name] { nodes[i].online = nodes[i].online && o } }
        }
        version = try? await ver

        // Tasks of the last 24 hours on each online node
        if errors.isEmpty {
            let since = Date().addingTimeInterval(-24 * 3600)
            let names = onlineNodes.map(\.name)
            var all: [PVETask] = []
            await withTaskGroup(of: [PVETask].self) { group in
                for name in names { group.addTask { (try? await api.tasks(node: name, since: since)) ?? [] } }
                for await list in group { all += list }
            }
            tasks = all.sorted { $0.starttime > $1.starttime }
            notifyChanges()
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastUpdated = Date()
        updateDock()
    }

    private func describe(_ error: Error) -> String {
        if case APIError.untrustedCertificate(let fp) = error { untrustedFingerprint = fp }
        return error.localizedDescription
    }

    func dismissError() {
        errorMessage = nil
        updateDock()
    }

    func testConnection() async -> String {
        do {
            let v = try await api.version()
            version = v
            untrustedFingerprint = nil
            let res = try await api.resources()
            let n = res.filter { $0.type == "node" }.count
            let g = res.filter { $0.type == "qemu" || $0.type == "lxc" }.count
            return "✅ Connected to Proxmox VE \(v.version): \(n) node(s), \(g) VM(s)/CT(s)"
        } catch {
            return "❌ \(describe(error))"
        }
    }

    /// Trusts the certificate the server just presented (after the user compared its fingerprint).
    func trustPresentedCertificate() {
        guard let fp = untrustedFingerprint else { return }
        pinnedFingerprint = fp
        untrustedFingerprint = nil
        manualRefresh(from: "certificate trusted")
    }

    // MARK: Actions

    /// Starts a task, follows it until it ends, then refreshes. Returns whether it succeeded.
    @discardableResult
    func run(_ title: String, node: String, guestID: String? = nil, privilege: String,
             _ start: @escaping (ProxmoxAPI) async throws -> String) async -> Bool {
        let api = self.api
        let upid: String
        do {
            upid = try await start(api)
        } catch {
            var message = "\(title) failed: \(describe(error))"
            // The reason Proxmox gives is not readable here, so name the privilege the action needs
            if case APIError.http(403, _) = error { message += " The API token needs \(privilege) for this." }
            errorMessage = message
            updateDock()
            return false
        }
        guard !upid.isEmpty else {
            manualRefresh(from: "action")
            return true
        }
        log.notice("Started task \(title, privacy: .public)")
        tracked.insert(TrackedTask(upid: upid, node: node, title: title, guestID: guestID), at: 0)

        // Poll the task status (up to 30 minutes)
        var exit: String?
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1.5))
            if let s = try? await api.taskStatus(node: node, upid: upid), s.status == "stopped" {
                exit = s.exitstatus ?? "OK"
                break
            }
        }
        if let i = tracked.firstIndex(where: { $0.upid == upid }) {
            tracked[i].finished = true
            tracked[i].exitStatus = exit ?? "Still running after 30 minutes"
        }
        let ok = tracked.first { $0.upid == upid }?.succeeded ?? false
        if !ok { errorMessage = "\(title): \(exit ?? "still running after 30 minutes")" }
        manualRefresh(from: "task finished")
        // Keep finished tasks visible for a while, then drop them
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ok ? 20 : 120))
            self?.tracked.removeAll { $0.upid == upid }
        }
        return ok
    }

    func power(_ g: Guest, _ action: ProxmoxAPI.PowerAction) async {
        await run("\(action.title) \(g.displayName)", node: g.node, guestID: g.id, privilege: "VM.PowerMgmt on /vms/\(g.vmid)") {
            try await $0.power(g, action)
        }
    }

    func isBusy(_ g: Guest) -> Bool { tracked.contains { $0.guestID == g.id && !$0.finished } }

    // MARK: Dock

    func updateDock() {
        let count = problems.count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : (errorMessage != nil && isConfigured ? "!" : nil)
    }

    // MARK: Notifications

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Notifies failed tasks and nodes that went offline since the last refresh (not on the first one).
    private func notifyChanges() {
        let failed = Set(failedTasks.map(\.upid))
        let offline = Set(nodes.filter { !$0.online }.map(\.name))
        defer {
            knownFailedTasks = (knownFailedTasks ?? []).union(failed)
            knownOfflineNodes = offline
        }
        guard notify, canNotify, let knownFailed = knownFailedTasks, let knownOffline = knownOfflineNodes else { return }
        for t in failedTasks where !knownFailed.contains(t.upid) && !tracked.contains(where: { $0.upid == t.upid }) {
            post(id: t.upid, title: "\(t.title) failed on \(t.node)", body: "\(t.objectID.isEmpty ? "" : guestName(t.objectID) + ": ")\(t.status ?? "")")
        }
        for n in offline.subtracting(knownOffline) {
            post(id: "offline-\(n)-\(Date().timeIntervalSince1970)", title: "Node \(n) is offline", body: "ProxmoxDock can't reach it through the cluster.")
        }
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
