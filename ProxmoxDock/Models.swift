import Foundation

// MARK: - Lenient decoding helpers
// Proxmox returns some booleans as 0/1 and, depending on the version, numbers as strings.

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; stringValue = "\(intValue)" }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func double(_ key: String) -> Double? {
        let k = AnyCodingKey(key)
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Double(s) }
        return nil
    }
    func int(_ key: String) -> Int? {
        let k = AnyCodingKey(key)
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Int(s) }
        return nil
    }
    func string(_ key: String) -> String? {
        let k = AnyCodingKey(key)
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return String(d) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        let k = AnyCodingKey(key)
        if let b = try? decodeIfPresent(Bool.self, forKey: k) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s == "1" || s == "true" }
        return nil
    }
}

extension Double {
    var asDate: Date { Date(timeIntervalSince1970: self) }
}

/// Proxmox wraps every response in `{"data": ...}`.
struct PVEResponse<T: Decodable>: Decodable {
    var data: T
}

// MARK: - Cluster resources (GET /cluster/resources)

struct ClusterResource: Decodable, Hashable {
    var id: String
    var type: String
    var node: String?
    var vmid: Int?
    var name: String?
    var status: String?
    var cpu: Double?
    var maxcpu: Double?
    var mem: Double?
    var maxmem: Double?
    var disk: Double?
    var maxdisk: Double?
    var uptime: Double?
    var template: Bool
    var tags: String?
    var hastate: String?
    var lock: String?
    var storage: String?
    var plugintype: String?
    var content: String?
    var shared: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.string("id") ?? UUID().uuidString
        type = c.string("type") ?? ""
        node = c.string("node")
        vmid = c.int("vmid")
        name = c.string("name")
        status = c.string("status")
        cpu = c.double("cpu")
        maxcpu = c.double("maxcpu")
        mem = c.double("mem")
        maxmem = c.double("maxmem")
        disk = c.double("disk")
        maxdisk = c.double("maxdisk")
        uptime = c.double("uptime")
        template = c.bool("template") ?? false
        tags = c.string("tags")
        hastate = c.string("hastate")
        lock = c.string("lock")
        storage = c.string("storage")
        plugintype = c.string("plugintype")
        content = c.string("content")
        shared = c.bool("shared") ?? false
    }
}

/// A virtual machine (qemu) or container (lxc).
struct Guest: Identifiable, Hashable {
    enum Kind: String { case qemu, lxc }

    var kind: Kind
    var vmid: Int
    var name: String
    var node: String
    var status: String
    var cpu: Double         // fraction of maxcpu
    var maxcpu: Double
    var mem: Double
    var maxmem: Double
    var disk: Double
    var maxdisk: Double
    var uptime: Double
    var template: Bool
    var tags: [String]
    var lock: String?
    var hastate: String?

    var id: String { "\(kind.rawValue)/\(vmid)" }
    var isRunning: Bool { status == "running" }
    var kindLabel: String { kind == .qemu ? "VM" : "CT" }
    var displayName: String { name.isEmpty ? "\(kindLabel) \(vmid)" : name }

    // Display text for Table cells (kept out of the Table so it type-checks quickly)
    var typeText: String { template ? "\(kindLabel) template" : kindLabel }
    var cpuText: String { isRunning ? "\(Fmt.percent(cpu)) of \(Int(maxcpu))" : "—" }
    var memText: String { isRunning ? "\(Fmt.bytes(mem)) / \(Fmt.bytes(maxmem))" : Fmt.bytes(maxmem) }
    var uptimeText: String { isRunning ? Fmt.uptime(uptime) : "—" }
    var tagsText: String { tags.joined(separator: ", ") }
    var statusIcon: String { template ? "doc.on.doc" : (isRunning ? "play.circle.fill" : "stop.circle") }
    var statusHelp: String { template ? "Template" : status.capitalized }

    // Sort helpers for Table columns
    var statusSort: Int { isRunning ? 1 : 0 }
    var cpuSort: Double { isRunning ? cpu : -1 }
    var memSort: Double { isRunning ? mem : -1 }
    var uptimeSort: Double { isRunning ? uptime : -1 }

    init?(_ r: ClusterResource) {
        guard let kind = Kind(rawValue: r.type), let vmid = r.vmid, let node = r.node else { return nil }
        self.kind = kind
        self.vmid = vmid
        self.name = r.name ?? ""
        self.node = node
        self.status = r.status ?? "unknown"
        self.cpu = r.cpu ?? 0
        self.maxcpu = r.maxcpu ?? 0
        self.mem = r.mem ?? 0
        self.maxmem = r.maxmem ?? 0
        self.disk = r.disk ?? 0
        self.maxdisk = r.maxdisk ?? 0
        self.uptime = r.uptime ?? 0
        self.template = r.template
        self.tags = (r.tags ?? "").split(whereSeparator: { ";, ".contains($0) }).map(String.init)
        self.lock = r.lock
        self.hastate = r.hastate
    }
}

struct PVENode: Identifiable, Hashable {
    var name: String
    var online: Bool
    var cpu: Double
    var maxcpu: Double
    var mem: Double
    var maxmem: Double
    var disk: Double
    var maxdisk: Double
    var uptime: Double
    var id: String { name }

    init?(_ r: ClusterResource) {
        guard r.type == "node", let name = r.node else { return nil }
        self.name = name
        self.online = r.status == "online"
        cpu = r.cpu ?? 0
        maxcpu = r.maxcpu ?? 0
        mem = r.mem ?? 0
        maxmem = r.maxmem ?? 0
        disk = r.disk ?? 0
        maxdisk = r.maxdisk ?? 0
        uptime = r.uptime ?? 0
    }
}

struct PVEStorage: Identifiable, Hashable {
    var storage: String
    var nodes: [String]
    var type: String
    var content: [String]
    var shared: Bool
    var available: Bool
    var used: Double
    var total: Double
    var id: String { shared ? storage : "\(nodes.first ?? "")/\(storage)" }
    var fraction: Double { total > 0 ? used / total : 0 }
    var nodesLabel: String { shared ? "Shared" : nodes.joined(separator: ", ") }

    // Sort helpers
    var fractionSort: Double { fraction }
    var totalSort: Double { total }

    /// Storages from /cluster/resources, with shared ones listed once.
    static func from(_ resources: [ClusterResource]) -> [PVEStorage] {
        var out: [String: PVEStorage] = [:]
        for r in resources where r.type == "storage" {
            guard let name = r.storage, let node = r.node else { continue }
            let key = r.shared ? name : "\(node)/\(name)"
            if var existing = out[key] {
                existing.nodes.append(node)
                existing.available = existing.available || r.status == "available"
                out[key] = existing
            } else {
                out[key] = PVEStorage(storage: name, nodes: [node], type: r.plugintype ?? "", content: (r.content ?? "").split(separator: ",").map(String.init),
                                      shared: r.shared, available: r.status == "available", used: r.disk ?? 0, total: r.maxdisk ?? 0)
            }
        }
        return out.values.sorted { $0.storage == $1.storage ? $0.nodesLabel < $1.nodesLabel : $0.storage < $1.storage }
    }
}

// MARK: - Cluster status (GET /cluster/status)

struct ClusterStatusEntry: Decodable {
    var type: String
    var name: String
    var online: Bool?
    var quorate: Bool?
    var nodes: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        type = c.string("type") ?? ""
        name = c.string("name") ?? ""
        online = c.bool("online")
        quorate = c.bool("quorate")
        nodes = c.int("nodes")
    }
}

struct PVEVersion: Decodable {
    var version: String
    var release: String?
}

// MARK: - Tasks (GET /nodes/{node}/tasks)

struct PVETask: Decodable, Identifiable, Hashable {
    var upid: String
    var node: String
    var type: String
    var objectID: String     // "id" in the API: usually the VMID
    var user: String
    var starttime: Double
    var endtime: Double?
    var status: String?      // nil while running; "OK", "WARNINGS: n" or an error message

    var id: String { upid }
    var isRunning: Bool { endtime == nil && status == nil }
    var isOK: Bool { status == "OK" }
    var isWarning: Bool { status?.hasPrefix("WARNINGS") == true }
    var isFailed: Bool { !isRunning && !isOK && !isWarning && status != nil }
    var startDate: Date { starttime.asDate }
    var duration: TimeInterval? { endtime.map { $0 - starttime } }
    var title: String { TaskType.name(type) }
    var startSort: Double { starttime }
    var statusText: String { isRunning ? "Running" : (status ?? "") }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        upid = c.string("upid") ?? UUID().uuidString
        node = c.string("node") ?? ""
        type = c.string("type") ?? ""
        objectID = c.string("id") ?? ""
        user = c.string("user") ?? ""
        starttime = c.double("starttime") ?? 0
        endtime = c.double("endtime")
        status = c.string("status")
    }
}

/// GET /nodes/{node}/tasks/{upid}/status
struct PVETaskStatus: Decodable {
    var status: String       // running | stopped
    var exitstatus: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        status = c.string("status") ?? "running"
        exitstatus = c.string("exitstatus")
    }
}

enum TaskType {
    private static let names: [String: String] = [
        "qmstart": "VM start", "qmstop": "VM stop", "qmshutdown": "VM shutdown", "qmreboot": "VM reboot",
        "qmsuspend": "VM suspend", "qmresume": "VM resume", "qmsnapshot": "VM snapshot", "qmdelsnapshot": "VM delete snapshot",
        "qmrollback": "VM rollback", "qmigrate": "VM migrate", "qmclone": "VM clone", "qmcreate": "VM create", "qmdestroy": "VM destroy",
        "qmconfig": "VM config", "qmmove": "VM move disk",
        "vzstart": "CT start", "vzstop": "CT stop", "vzshutdown": "CT shutdown", "vzreboot": "CT reboot",
        "vzsnapshot": "CT snapshot", "vzdelsnapshot": "CT delete snapshot", "vzrollback": "CT rollback", "vzmigrate": "CT migrate",
        "vzcreate": "CT create", "vzdestroy": "CT destroy", "vzclone": "CT clone",
        "vzdump": "Backup", "imgcopy": "Copy image", "imgdel": "Delete image", "download": "Download",
        "aptupdate": "Update package database", "srvreload": "Reload service", "srvrestart": "Restart service",
        "startall": "Start all", "stopall": "Stop all", "zfsscrub": "ZFS scrub", "pull": "Pull", "prune": "Prune",
    ]
    static func name(_ type: String) -> String { names[type] ?? type }
}

// MARK: - Snapshots (GET /nodes/{node}/{qemu|lxc}/{vmid}/snapshot)

struct PVESnapshot: Decodable, Identifiable, Hashable {
    var name: String
    var description: String
    var snaptime: Double?
    var parent: String?
    var vmstate: Bool
    var id: String { name }
    /// The API lists the guest's live state as a pseudo-snapshot named "current".
    var isCurrent: Bool { name == "current" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        name = c.string("name") ?? ""
        description = c.string("description") ?? ""
        snaptime = c.double("snaptime")
        parent = c.string("parent")
        vmstate = c.bool("vmstate") ?? false
    }

    /// Snapshot names: start with a letter; letters, digits, "_" and "-"; at most 40 characters.
    static func isValidName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z][A-Za-z0-9_-]{1,39}$", options: .regularExpression) != nil && s != "current"
    }
}

// MARK: - Node storage (GET /nodes/{node}/storage)

struct NodeStorage: Decodable, Identifiable, Hashable {
    var storage: String
    var type: String
    var content: String
    var active: Bool
    var enabled: Bool
    var avail: Double?
    var total: Double?
    var id: String { storage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        storage = c.string("storage") ?? ""
        type = c.string("type") ?? ""
        content = c.string("content") ?? ""
        active = c.bool("active") ?? true
        enabled = c.bool("enabled") ?? true
        avail = c.double("avail")
        total = c.double("total")
    }
}

// MARK: - Formatting

enum Fmt {
    static let locale: Locale = {
        var comps = Locale.Components(locale: .current)
        comps.languageComponents = Locale.Language.Components(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return Locale(components: comps)
    }()

    // Formatters are built once and reused (main thread only)
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = locale
        return f
    }()
    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
    private static let shortDurationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
    private static let dateTimeStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)

    /// "0" instead of ByteCountFormatter's "Zero KB" (e.g. on chart axes)
    static func bytes(_ v: Double) -> String { v < 1 ? "0" : byteFormatter.string(fromByteCount: Int64(v)) }
    static func relative(_ d: Date) -> String { relativeFormatter.localizedString(for: d, relativeTo: Date()) }
    static func dateTime(_ d: Date) -> String { d.formatted(dateTimeStyle) }
    static func uptime(_ seconds: Double) -> String { seconds > 0 ? (durationFormatter.string(from: seconds) ?? "") : "—" }
    static func duration(_ seconds: Double) -> String { shortDurationFormatter.string(from: max(1, seconds)) ?? "" }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}

// MARK: - Node health (ZFS, disks, updates, Ceph)

/// GET /nodes/{node}/disks/zfs
struct ZFSPool: Decodable, Identifiable, Hashable {
    var name: String
    var health: String
    var size: Double
    var alloc: Double
    var free: Double
    var frag: Double?
    var id: String { name }
    /// ONLINE is healthy; DEGRADED, FAULTED, UNAVAIL, SUSPENDED, OFFLINE and REMOVED need attention.
    var isHealthy: Bool { health.uppercased() == "ONLINE" }
    var fraction: Double { size > 0 ? alloc / size : 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        name = c.string("name") ?? ""
        health = c.string("health") ?? "UNKNOWN"
        size = c.double("size") ?? 0
        alloc = c.double("alloc") ?? 0
        free = c.double("free") ?? 0
        frag = c.double("frag")
    }
}

/// GET /nodes/{node}/disks/list
struct NodeDisk: Decodable, Identifiable, Hashable {
    var devpath: String
    var health: String?
    var model: String?
    var serial: String?
    var size: Double
    var type: String?
    var wearout: String?
    var id: String { devpath }
    /// SMART result: "PASSED"/"OK" healthy, "UNKNOWN"/missing means SMART isn't available.
    var isFailing: Bool {
        guard let h = health?.uppercased(), !h.isEmpty else { return false }
        return !["PASSED", "OK", "UNKNOWN", "N/A"].contains(h)
    }
    var label: String { [model, devpath].compactMap { $0 }.joined(separator: " · ") }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        devpath = c.string("devpath") ?? ""
        health = c.string("health")
        model = c.string("model")
        serial = c.string("serial")
        size = c.double("size") ?? 0
        type = c.string("type")
        wearout = c.string("wearout")
    }
}

/// GET /nodes/{node}/apt/update (cached list of available updates; needs Sys.Modify)
struct AptPackage: Decodable, Identifiable, Hashable {
    var package: String
    var version: String
    var oldVersion: String?
    var id: String { package }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        package = c.string("Package") ?? ""
        version = c.string("Version") ?? ""
        oldVersion = c.string("OldVersion")
    }
}

/// GET /cluster/ceph/status: only the overall health is used.
struct CephHealth: Decodable {
    var status: String     // HEALTH_OK, HEALTH_WARN, HEALTH_ERR
    var summaries: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        struct Health: Decodable {
            var status: String?
            var checks: [String: Check]?
            struct Check: Decodable {
                var severity: String?
                var summary: Summary?
                struct Summary: Decodable { var message: String? }
            }
        }
        let health = try? c.decodeIfPresent(Health.self, forKey: AnyCodingKey("health"))
        status = health?.status ?? "UNKNOWN"
        summaries = (health?.checks ?? [:]).values.compactMap { $0.summary?.message }.sorted()
    }
}

// MARK: - Guest IP addresses

/// IP addresses of a running guest, from the QEMU guest agent (VMs) or the container's interfaces.
struct GuestAddresses: Hashable {
    enum State: Hashable {
        case ok
        case noAgent            // VM without a running QEMU guest agent
        case denied(String)     // the token lacks the privilege named here
        case failed(String)
    }
    var addresses: [String]     // IPv4 first, then IPv6; no loopback or link-local
    var state: State
    var fetched: Date

    var primary: String? { addresses.first }
    var summary: String {
        switch state {
        case .ok: return addresses.isEmpty ? "—" : (addresses.count > 1 ? "\(addresses[0]) +\(addresses.count - 1)" : addresses[0])
        case .noAgent: return "No agent"
        case .denied: return "No permission"
        case .failed: return "—"
        }
    }
    var help: String {
        switch state {
        case .ok: return addresses.isEmpty ? "No IP address reported" : addresses.joined(separator: "\n")
        case .noAgent: return "The QEMU guest agent isn't running in this VM: install qemu-guest-agent in the guest and enable it under Options → QEMU Guest Agent."
        case .denied(let privilege): return "The API token needs \(privilege) to read this guest's IP addresses."
        case .failed(let message): return message
        }
    }

    /// Keeps routable addresses: drops loopback, link-local, and IPv6 before IPv4 ordering.
    static func clean(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        let addrs = raw.map { $0.split(separator: "/").first.map(String.init) ?? $0 }
            .filter { a in
                let l = a.lowercased()
                return !l.isEmpty && !l.hasPrefix("127.") && l != "::1" && !l.hasPrefix("fe80") && !l.hasPrefix("169.254.")
            }
            .filter { seen.insert($0).inserted }
        return addrs.filter { !$0.contains(":") } + addrs.filter { $0.contains(":") }
    }
}

/// One interface from the QEMU guest agent or from /lxc/{vmid}/interfaces.
struct GuestInterface: Decodable {
    var name: String
    var addresses: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        name = c.string("name") ?? ""
        struct Addr: Decodable {
            var ip: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                ip = c.string("ip-address")
            }
        }
        var list = ((try? c.decodeIfPresent([Addr].self, forKey: AnyCodingKey("ip-addresses"))) ?? nil)?.compactMap(\.ip) ?? []
        // Containers also report "inet"/"inet6" as "address/prefix" strings (possibly several, space separated)
        for key in ["inet", "inet6"] {
            if let s = c.string(key) { list += s.split(separator: " ").map(String.init) }
        }
        addresses = list
    }

    /// Loopback and container-runtime bridges (Docker, Podman, libvirt, Kubernetes CNIs) whose
    /// addresses are internal to the guest and not useful to connect to.
    var isInternal: Bool {
        let n = name.lowercased()
        return n == "lo" || ["docker", "br-", "veth", "virbr", "cni", "flannel", "cali", "podman", "lxcbr", "kube"].contains { n.hasPrefix($0) }
    }
}

/// The guest agent wraps its answer: {"result": [interfaces]}
struct AgentInterfaces: Decodable {
    var result: [GuestInterface]
}

// MARK: - Performance history (GET .../rrddata)

/// One sample of Proxmox's RRD history. Field names aren't in the API schema, so every
/// numeric field is kept by name (cpu, mem/memused, netin, netout, diskread, loadavg, …).
struct RRDPoint: Decodable, Identifiable {
    var time: Date
    var values: [String: Double]
    var id: Double { time.timeIntervalSince1970 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        time = (c.double("time") ?? 0).asDate
        var v: [String: Double] = [:]
        for key in c.allKeys where key.stringValue != "time" {
            if let d = c.double(key.stringValue), d.isFinite { v[key.stringValue] = d }
        }
        values = v
    }

    /// The first of the given fields that this sample has.
    func value(_ keys: [String]) -> Double? {
        for k in keys { if let v = values[k] { return v } }
        return nil
    }
    func value(_ keys: String...) -> Double? { value(keys) }
}

enum RRDTimeframe: String, CaseIterable, Identifiable {
    case hour, day, week, month, year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Backups (GET /nodes/{node}/storage/{storage}/content?content=backup)

struct BackupVolume: Decodable, Identifiable, Hashable {
    var volid: String
    var vmid: Int?
    var ctime: Double
    var size: Double?
    var format: String
    var notes: String
    var protected: Bool
    var verification: String?     // PBS: "ok" / "failed"
    var storage = ""              // filled in by the client
    var node = ""                 // node used to reach the storage
    var id: String { volid }
    var date: Date { ctime.asDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        volid = c.string("volid") ?? ""
        vmid = c.int("vmid")
        ctime = c.double("ctime") ?? 0
        size = c.double("size")
        format = c.string("format") ?? ""
        notes = c.string("notes") ?? ""
        protected = c.bool("protected") ?? false
        struct Verification: Decodable { var state: String? }
        verification = (try? c.decodeIfPresent(Verification.self, forKey: AnyCodingKey("verification")))??.state
    }
}

/// GET /cluster/backup-info/not-backed-up
struct NotBackedUp: Decodable {
    var vmid: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        vmid = c.int("vmid") ?? 0
    }
}
