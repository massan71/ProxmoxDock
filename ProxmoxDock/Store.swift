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
    /// SMART checks query every disk, which can wake disks in standby, so they run hourly and can be turned off.
    @Published var checkDisks: Bool { didSet { UserDefaults.standard.set(checkDisks, forKey: "checkDisks"); slowChecksDone = nil } }
    @Published var checkUpdates: Bool { didSet { UserDefaults.standard.set(checkUpdates, forKey: "checkUpdates"); slowChecksDone = nil } }
    @Published var updatesAsProblem: Bool { didSet { UserDefaults.standard.set(updatesAsProblem, forKey: "updatesAsProblem"); updateDock() } }
    /// Warn when a guest's newest backup is older than this many days (0: off)
    @Published var backupMaxAgeDays: Int { didSet { UserDefaults.standard.set(backupMaxAgeDays, forKey: "backupMaxAgeDays"); updateDock() } }
    /// Guests with this tag are ignored by the backup checks
    @Published var backupIgnoreTag: String { didSet { UserDefaults.standard.set(backupIgnoreTag, forKey: "backupIgnoreTag"); updateDock() } }
    @Published var warnNotCovered: Bool { didSet { UserDefaults.standard.set(warnNotCovered, forKey: "warnNotCovered"); updateDock() } }
    /// User name for "SSH to…" (empty: your macOS user name)
    @Published var sshUser: String { didSet { UserDefaults.standard.set(sshUser, forKey: "sshUser") } }

    // Data
    @Published var nodes: [PVENode] = []
    @Published var guests: [Guest] = []
    @Published var storages: [PVEStorage] = []
    @Published var tasks: [PVETask] = []
    @Published var cluster: ClusterStatusEntry?
    @Published var version: PVEVersion?
    @Published var zfsPools: [String: [ZFSPool]] = [:]
    @Published var disks: [String: [NodeDisk]] = [:]
    @Published var updates: [String: [AptPackage]] = [:]
    /// Why updates can't be checked (e.g. the token lacks Sys.Modify), or nil
    @Published var updatesUnavailable: String?
    @Published var ceph: CephHealth?
    /// "storage on node" for storage that isn't available on an online node
    @Published var unavailableStorage: [String] = []
    /// Backups by VMID, from every storage holding backups (refreshed every 30 minutes)
    @Published var backups: [Int: [BackupVolume]] = [:]
    /// VMIDs not in any backup job (nil: unknown, e.g. the token lacks Sys.Audit)
    @Published var notCovered: Set<Int>?
    @Published var backupScanned: Date?
    /// IP addresses of running guests, by guest ID (refreshed every 5 minutes)
    @Published var addresses: [String: GuestAddresses] = [:]
    private var slowChecksDone: Date?

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
    private var knownHealthProblems: Set<String>?

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
        checkDisks = d.object(forKey: "checkDisks") as? Bool ?? true
        checkUpdates = d.object(forKey: "checkUpdates") as? Bool ?? true
        updatesAsProblem = d.bool(forKey: "updatesAsProblem")
        sshUser = d.string(forKey: "sshUser") ?? "root"
        backupMaxAgeDays = d.object(forKey: "backupMaxAgeDays") as? Int ?? 7
        backupIgnoreTag = d.string(forKey: "backupIgnoreTag") ?? "nobackup"
        warnNotCovered = d.object(forKey: "warnNotCovered") as? Bool ?? true
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
        out += healthProblems
        if updatesAsProblem {
            for (node, list) in updates.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
                out.append(Problem(kind: .updates, title: "\(list.count) update(s) available on \(node)", detail: "", id: "updates-\(node)"))
            }
        }
        return out
    }

    /// Problems from health checks: storage availability, ZFS, SMART, HA and Ceph.
    var healthProblems: [Problem] {
        Health.problems(unavailableStorage: unavailableStorage, zfsPools: zfsPools, disks: disks, guests: guests, ceph: ceph)
            + backupProblems
    }

    /// Only once the backups have been scanned, so nothing is reported as "never backed up" too early.
    var backupProblems: [Problem] {
        guard backupScanned != nil else { return [] }
        return Health.backupProblems(guests: guests, latest: latestBackup, notCovered: warnNotCovered ? notCovered : nil,
                                     maxAgeDays: backupMaxAgeDays, ignoreTag: backupIgnoreTag)
    }

    /// Newest backup date per VMID.
    var latestBackup: [Int: Date] { backups.compactMapValues { $0.map(\.date).max() } }

    var totalUpdates: Int { updates.values.reduce(0) { $0 + $1.count } }

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
            lastResources = resources
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
            await loadHealth(api: api, resources: lastResources)
            await loadAddresses(api: api)
            await loadBackups(api: api)
            notifyChanges()
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastUpdated = Date()
        updateDock()
    }

    private var lastResources: [ClusterResource] = []

    /// Reads the IPs of running guests whose addresses are older than 5 minutes (6 requests at a time).
    func loadAddresses(api: ProxmoxAPI, force: Bool = false) async {
        let running = runningGuests
        let ids = Set(running.map(\.id))
        addresses = addresses.filter { ids.contains($0.key) }
        let due = running.filter { g in
            force || (addresses[g.id].map { Date().timeIntervalSince($0.fetched) > 300 } ?? true)
        }
        guard !due.isEmpty else { return }
        var found: [String: GuestAddresses] = [:]
        await withTaskGroup(of: (String, GuestAddresses).self) { group in
            var queue = due.makeIterator()
            func addNext() {
                guard let g = queue.next() else { return }
                group.addTask { (g.id, await api.addresses(g)) }
            }
            for _ in 0..<6 { addNext() }
            for await (id, result) in group {
                found[id] = result
                addNext()
            }
        }
        addresses.merge(found) { _, new in new }
    }

    /// Lists the backups on every storage holding them (one online node per storage), at most every 30 minutes.
    func loadBackups(api: ProxmoxAPI, force: Bool = false) async {
        if !force, let last = backupScanned, Date().timeIntervalSince(last) < 1800 { return }
        let online = Set(onlineNodes.map(\.name))
        let sources: [(node: String, storage: String)] = storages
            .filter { $0.available && $0.content.contains("backup") }
            .compactMap { s in s.nodes.first(where: online.contains).map { ($0, s.storage) } }
        var all: [BackupVolume] = []
        var anyOK = sources.isEmpty
        await withTaskGroup(of: [BackupVolume]?.self) { group in
            for src in sources { group.addTask { try? await api.backups(node: src.node, storage: src.storage) } }
            for await list in group {
                if let list { all += list; anyOK = true }
            }
        }
        notCovered = (try? await api.notBackedUp()).map { Set($0.map(\.vmid)) }
        guard anyOK else { return }   // keep the previous list if every storage failed
        backups = Dictionary(grouping: all.filter { $0.vmid != nil }, by: { $0.vmid! })
            .mapValues { $0.sorted { $0.ctime > $1.ctime } }
        backupScanned = Date()
        updateDock()
    }

    /// Re-reads one guest's backups (e.g. when opening its details or after a backup).
    func refreshBackups(of g: Guest) async {
        let api = self.api
        let online = Set(onlineNodes.map(\.name))
        let sources: [(node: String, storage: String)] = storages
            .filter { $0.available && $0.content.contains("backup") }
            .compactMap { s in s.nodes.first(where: online.contains).map { ($0, s.storage) } }
        var found: [BackupVolume] = []
        for src in sources {
            if let list = try? await api.backups(node: src.node, storage: src.storage, vmid: g.vmid) { found += list }
        }
        backups[g.vmid] = found.sorted { $0.ctime > $1.ctime }
        updateDock()
    }

    func setProtected(_ b: BackupVolume, _ protected: Bool, of g: Guest) async {
        do {
            try await api.setProtected(b, protected)
        } catch {
            var message = "Could not \(protected ? "protect" : "unprotect") the backup: \(describe(error))"
            if case APIError.http(403, _) = error { message += " The API token needs write access to /storage/\(b.storage)." }
            errorMessage = message
        }
        await refreshBackups(of: g)
    }

    func deleteBackup(_ b: BackupVolume, of g: Guest) async {
        await run("Delete backup of \(g.displayName)", node: b.node, guestID: g.id,
                  privilege: "Datastore.Allocate on /storage/\(b.storage) (or VM.Backup on /vms/\(g.vmid) plus Datastore.AllocateSpace)") {
            try await $0.deleteBackup(b)
        }
        await refreshBackups(of: g)
    }

    func refreshAddresses(of g: Guest) async {
        addresses[g.id] = await api.addresses(g)
    }

    /// ZFS, storage availability and Ceph on every refresh; SMART and updates at most hourly.
    private func loadHealth(api: ProxmoxAPI, resources: [ClusterResource]) async {
        let names = onlineNodes.map(\.name)
        let online = Set(names)
        unavailableStorage = Health.unavailableStorage(resources, onlineNodes: online)

        var pools: [String: [ZFSPool]] = [:]
        await withTaskGroup(of: (String, [ZFSPool]?).self) { group in
            for n in names { group.addTask { (n, try? await api.zfsPools(node: n)) } }
            for await (n, list) in group { if let list { pools[n] = list } }
        }
        zfsPools = pools

        // Ceph only when the cluster uses Ceph storage
        let usesCeph = Health.usesCeph(resources)
        ceph = usesCeph ? try? await api.cephHealth() : nil

        let due = slowChecksDone.map { Date().timeIntervalSince($0) > 3600 } ?? true
        guard due else { return }
        slowChecksDone = Date()

        if checkDisks {
            var found: [String: [NodeDisk]] = [:]
            await withTaskGroup(of: (String, [NodeDisk]?).self) { group in
                for n in names { group.addTask { (n, try? await api.disks(node: n)) } }
                for await (n, list) in group { if let list { found[n] = list } }
            }
            disks = found
        } else {
            disks = [:]
        }

        if checkUpdates {
            var found: [String: [AptPackage]] = [:]
            var denied = false
            await withTaskGroup(of: (String, Result<[AptPackage], Error>).self) { group in
                for n in names {
                    group.addTask {
                        do { return (n, .success(try await api.updates(node: n))) } catch { return (n, .failure(error)) }
                    }
                }
                for await (n, result) in group {
                    switch result {
                    case .success(let list): found[n] = list
                    case .failure(let error): if case APIError.http(403, _) = error { denied = true }
                    }
                }
            }
            updates = found
            updatesUnavailable = denied ? "The API token needs Sys.Modify on /nodes to read available updates." : nil
        } else {
            updates = [:]
            updatesUnavailable = nil
        }
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
        let health = healthProblems
        defer {
            knownFailedTasks = (knownFailedTasks ?? []).union(failed)
            knownOfflineNodes = offline
            knownHealthProblems = Set(health.map(\.id))
        }
        guard notify, canNotify, let knownFailed = knownFailedTasks, let knownOffline = knownOfflineNodes,
              let knownHealth = knownHealthProblems else { return }
        for p in health where !knownHealth.contains(p.id) {
            post(id: "\(p.id)-\(Date().timeIntervalSince1970)", title: p.title, body: p.detail.isEmpty ? "Open ProxmoxDock for details." : p.detail)
        }
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
