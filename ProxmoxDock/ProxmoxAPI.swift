import CryptoKit
import Foundation
import Security

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case insecureURL
    case untrustedCertificate(fingerprint: String)
    case localNetworkDenied
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set the server URL, API token ID and secret in Settings (⌘,)."
        case .invalidURL:
            return "Invalid server URL."
        case .insecureURL:
            return "The server URL must start with https:// so the token is never sent unencrypted."
        case .untrustedCertificate:
            return "The server's certificate isn't trusted yet. Compare its fingerprint in Settings and click Trust."
        case .localNetworkDenied:
            return "macOS blocked access to the local network. Allow ProxmoxDock in System Settings → Privacy & Security → Local Network."
        case .http(401, _):
            return "Invalid API token (HTTP 401). Check the token ID (user@realm!tokenid) and secret."
        case .http(403, let msg):
            return "Permission denied (HTTP 403)\(msg.isEmpty ? "" : ": \(msg)")."
        case .http(let code, let msg):
            return "HTTP error \(code)\(msg.isEmpty ? "" : ": \(msg)")"
        case .decoding(let msg):
            return "Unexpected response from the server: \(msg)"
        }
    }
}

// MARK: - Certificate trust

/// Proxmox usually runs with a self-signed certificate. A certificate is accepted when macOS
/// trusts it, or when its SHA-256 fingerprint matches the one the user explicitly trusted.
final class CertificateTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = CertificateTrust()

    private let lock = NSLock()
    private var _pinned: String?
    private var _lastRejected: String?

    /// The fingerprint the user trusts ("AB:CD:…"), or nil.
    var pinned: String? {
        get { lock.withLock { _pinned } }
        set { lock.withLock { _pinned = newValue } }
    }

    /// Fingerprint of the last certificate that was refused.
    var lastRejected: String? {
        get { lock.withLock { _lastRejected } }
        set { lock.withLock { _lastRejected = newValue } }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // A certificate macOS already trusts (e.g. Let's Encrypt) is fine as is
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard let fingerprint = Self.leafFingerprint(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if fingerprint == pinned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lastRejected = fingerprint
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Client

/// Client for the Proxmox VE API (https://pve.proxmox.com/wiki/Proxmox_VE_API).
/// Auth: `Authorization: PVEAPIToken=USER@REALM!TOKENID=SECRET` (no CSRF token needed with API tokens).
struct ProxmoxAPI {
    let baseURL: String
    let tokenID: String
    let secret: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: CertificateTrust.shared, delegateQueue: nil)
    }()

    var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !tokenID.isEmpty && !secret.isEmpty }

    /// Normalized origin, e.g. "https://pve.lan:8006" (port 8006 added when missing).
    static func normalizedBase(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.lowercased().hasPrefix("http") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/api2/json") { base.removeLast("/api2/json".count) }
        if var comps = URLComponents(string: base), comps.port == nil, comps.host != nil {
            comps.port = 8006
            base = comps.string ?? base
        }
        return base
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], form: [String: String]? = nil) throws -> URLRequest {
        guard isConfigured else { throw APIError.notConfigured }
        let base = Self.normalizedBase(baseURL)
        guard var comps = URLComponents(string: base + "/api2/json" + path) else { throw APIError.invalidURL }
        guard comps.scheme?.lowercased() == "https", comps.host?.isEmpty == false else { throw APIError.insecureURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("PVEAPIToken=\(tokenID)=\(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            var body = URLComponents()
            body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" unescaped, which form decoding would read as a space
            let encoded = (body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            req.httpBody = Data(encoded.utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        CertificateTrust.shared.lastRejected = nil
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch let error as URLError {
            if let fingerprint = CertificateTrust.shared.lastRejected {
                throw APIError.untrustedCertificate(fingerprint: fingerprint)
            }
            // Local Network privacy denial surfaces as "not connected" for LAN hosts
            if error.code == .notConnectedToInternet, let host = req.url?.host, Self.isLocalHost(host) {
                throw APIError.localNetworkDenied
            }
            throw error
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Proxmox puts the reason in the HTTP status line, which URLSession doesn't expose;
            // field errors come as an "errors" object in the body
            throw APIError.http(code, Self.errorMessage(data) ?? "")
        }
        return data
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : String(text.prefix(200))
        }
        if let errors = obj["errors"] as? [String: Any], !errors.isEmpty {
            return errors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
        }
        if let message = obj["message"] as? String { return message.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") || !h.contains(".") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return h.hasPrefix("fe80") || h.hasPrefix("fd") }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 100 && (64...127).contains(parts[1]))
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(try request(path, query: query))
        do {
            return try JSONDecoder().decode(PVEResponse<T>.self, from: data).data
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// POST/DELETE calls that start a task return its UPID.
    /// DELETE parameters go in the query string; POST parameters in a form body.
    private func task(_ path: String, method: String = "POST", form: [String: String] = [:]) async throws -> String {
        let query = method == "DELETE" ? form.map { URLQueryItem(name: $0.key, value: $0.value) } : []
        let data = try await send(try request(path, method: method, query: query, form: method == "POST" ? form : nil))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["data"] as? String ?? ""
    }

    /// Encodes one path segment ("/" included, e.g. in backup volume IDs).
    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? s }

    // MARK: Reading

    func version() async throws -> PVEVersion { try await get("/version") }
    func resources() async throws -> [ClusterResource] { try await get("/cluster/resources") }
    func clusterStatus() async throws -> [ClusterStatusEntry] { try await get("/cluster/status") }

    func tasks(node: String, since: Date, limit: Int = 200) async throws -> [PVETask] {
        try await get("/nodes/\(enc(node))/tasks", query: [
            URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970))),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "source", value: "all"),
        ])
    }

    func taskStatus(node: String, upid: String) async throws -> PVETaskStatus {
        try await get("/nodes/\(enc(node))/tasks/\(enc(upid))/status")
    }

    func snapshots(_ g: Guest) async throws -> [PVESnapshot] {
        try await get("/nodes/\(enc(g.node))/\(g.kind.rawValue)/\(g.vmid)/snapshot")
    }

    func backupStorages(node: String) async throws -> [NodeStorage] {
        try await get("/nodes/\(enc(node))/storage", query: [
            URLQueryItem(name: "content", value: "backup"),
            URLQueryItem(name: "enabled", value: "1"),
        ])
    }

    // MARK: Health

    func zfsPools(node: String) async throws -> [ZFSPool] { try await get("/nodes/\(enc(node))/disks/zfs") }
    func disks(node: String) async throws -> [NodeDisk] { try await get("/nodes/\(enc(node))/disks/list") }
    /// The cached list of available updates (does not run apt update); needs Sys.Modify.
    func updates(node: String) async throws -> [AptPackage] { try await get("/nodes/\(enc(node))/apt/update") }
    func cephHealth() async throws -> CephHealth { try await get("/cluster/ceph/status") }

    // MARK: Backups

    /// Backups on one storage (optionally of one guest). Needs Datastore.Audit on the storage.
    func backups(node: String, storage: String, vmid: Int? = nil) async throws -> [BackupVolume] {
        var q = [URLQueryItem(name: "content", value: "backup")]
        if let vmid { q.append(URLQueryItem(name: "vmid", value: String(vmid))) }
        let list: [BackupVolume] = try await get("/nodes/\(enc(node))/storage/\(enc(storage))/content", query: q)
        return list.map { var b = $0; b.storage = storage; b.node = node; return b }
    }

    /// Guests not included in any backup job. Needs Sys.Audit on "/".
    func notBackedUp() async throws -> [NotBackedUp] { try await get("/cluster/backup-info/not-backed-up") }

    /// PUT .../content/{volume} protected=0|1 (a protected backup isn't pruned or deleted).
    func setProtected(_ b: BackupVolume, _ protected: Bool) async throws {
        _ = try await send(try request("/nodes/\(enc(b.node))/storage/\(enc(b.storage))/content/\(enc(b.volid))",
                                       method: "PUT", form: ["protected": protected ? "1" : "0"]))
    }

    /// DELETE .../content/{volume}; returns the task UPID.
    func deleteBackup(_ b: BackupVolume) async throws -> String {
        try await task("/nodes/\(enc(b.node))/storage/\(enc(b.storage))/content/\(enc(b.volid))", method: "DELETE")
    }

    // MARK: Performance history

    /// RRD history of a node, VM or container (averages). Nodes need Sys.Audit, guests VM.Audit.
    func rrd(_ target: ResourceTarget, timeframe: RRDTimeframe) async throws -> [RRDPoint] {
        let path: String
        switch target.kind {
        case .node: path = "/nodes/\(enc(target.node))/rrddata"
        case .qemu: path = "/nodes/\(enc(target.node))/qemu/\(target.vmid ?? 0)/rrddata"
        case .lxc: path = "/nodes/\(enc(target.node))/lxc/\(target.vmid ?? 0)/rrddata"
        }
        let points: [RRDPoint] = try await get(path, query: [
            URLQueryItem(name: "timeframe", value: timeframe.rawValue),
            URLQueryItem(name: "cf", value: "AVERAGE"),
        ])
        // Samples without any value (before the guest existed or while it was off) are dropped
        return points.filter { !$0.values.isEmpty }.sorted { $0.time < $1.time }
    }

    // MARK: Guest IP addresses

    /// IPs of a running guest. VMs need the QEMU guest agent and VM.GuestAgent.Audit
    /// (VM.Monitor before Proxmox VE 9); containers need VM.Audit.
    func addresses(_ g: Guest) async -> GuestAddresses {
        do {
            let interfaces: [GuestInterface]
            if g.kind == .qemu {
                let agent: AgentInterfaces = try await get("/nodes/\(enc(g.node))/qemu/\(g.vmid)/agent/network-get-interfaces")
                interfaces = agent.result
            } else {
                interfaces = try await get("/nodes/\(enc(g.node))/lxc/\(g.vmid)/interfaces")
            }
            let raw = interfaces.filter { !$0.isInternal }.flatMap(\.addresses)
            return GuestAddresses(addresses: GuestAddresses.clean(raw), state: .ok, fetched: Date())
        } catch APIError.http(403, _) {
            let privilege = g.kind == .qemu ? "VM.GuestAgent.Audit (VM.Monitor before Proxmox VE 9)" : "VM.Audit"
            return GuestAddresses(addresses: [], state: .denied(privilege), fetched: Date())
        } catch APIError.http(let code, let msg) where g.kind == .qemu && (code == 500 || code == 596) {
            // "QEMU guest agent is not running" / "No QEMU guest agent configured"
            _ = msg
            return GuestAddresses(addresses: [], state: .noAgent, fetched: Date())
        } catch {
            return GuestAddresses(addresses: [], state: .failed(error.localizedDescription), fetched: Date())
        }
    }

    // MARK: Actions (each starts a task and returns its UPID)

    enum PowerAction: String, CaseIterable, Identifiable {
        case start, shutdown, reboot, stop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .start: return "Start"
            case .shutdown: return "Shut Down"
            case .reboot: return "Reboot"
            case .stop: return "Stop (Force)"
            }
        }
        var icon: String {
            switch self {
            case .start: return "play.fill"
            case .shutdown: return "power"
            case .reboot: return "arrow.clockwise"
            case .stop: return "stop.fill"
            }
        }
    }

    func power(_ g: Guest, _ action: PowerAction) async throws -> String {
        try await task("/nodes/\(enc(g.node))/\(g.kind.rawValue)/\(g.vmid)/status/\(action.rawValue)")
    }

    func createSnapshot(_ g: Guest, name: String, description: String, includeRAM: Bool) async throws -> String {
        var form = ["snapname": name]
        if !description.isEmpty { form["description"] = description }
        if g.kind == .qemu && includeRAM { form["vmstate"] = "1" }
        return try await task("/nodes/\(enc(g.node))/\(g.kind.rawValue)/\(g.vmid)/snapshot", form: form)
    }

    func rollback(_ g: Guest, snapshot: String, start: Bool) async throws -> String {
        try await task("/nodes/\(enc(g.node))/\(g.kind.rawValue)/\(g.vmid)/snapshot/\(enc(snapshot))/rollback",
                       form: start ? ["start": "1"] : [:])
    }

    func deleteSnapshot(_ g: Guest, snapshot: String) async throws -> String {
        try await task("/nodes/\(enc(g.node))/\(g.kind.rawValue)/\(g.vmid)/snapshot/\(enc(snapshot))", method: "DELETE")
    }

    enum BackupMode: String, CaseIterable, Identifiable {
        case snapshot, suspend, stop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .snapshot: return "Snapshot (no downtime)"
            case .suspend: return "Suspend"
            case .stop: return "Stop"
            }
        }
    }

    func backup(_ g: Guest, storage: String, mode: BackupMode, notes: String) async throws -> String {
        var form = ["vmid": String(g.vmid), "storage": storage, "mode": mode.rawValue, "compress": "zstd"]
        if !notes.isEmpty { form["notes-template"] = notes }
        return try await task("/nodes/\(enc(g.node))/vzdump", form: form)
    }
}
