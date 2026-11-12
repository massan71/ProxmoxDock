import Foundation

/// Something that needs attention; the Dock badge shows how many there are.
struct Problem: Identifiable, Hashable {
    enum Kind { case nodeOffline, quorum, failedTask, storageFull, storageUnavailable, zfs, disk, ha, ceph, updates, backup }
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
        case .storageUnavailable: return "externaldrive.badge.xmark"
        case .zfs: return "cylinder.split.1x2"
        case .disk: return "internaldrive"
        case .ha: return "arrow.triangle.2.circlepath"
        case .ceph: return "circle.hexagongrid"
        case .updates: return "arrow.down.circle"
        case .backup: return "externaldrive.badge.timemachine"
        }
    }
}

/// Health rules, kept free of app state so they can be tested on their own.
enum Health {
    /// "storage on node" for storage that isn't available on an online node.
    static func unavailableStorage(_ resources: [ClusterResource], onlineNodes: Set<String>) -> [String] {
        resources
            .filter { $0.type == "storage" && $0.status != "available" && onlineNodes.contains($0.node ?? "") }
            .map { "\($0.storage ?? "?") on \($0.node ?? "?")" }
            .sorted()
    }

    /// Whether the cluster has Ceph storage (only then is Ceph's health queried).
    static func usesCeph(_ resources: [ClusterResource]) -> Bool {
        resources.contains { $0.type == "storage" && ["rbd", "cephfs"].contains($0.plugintype ?? "") }
    }

    /// Dismissed problems stay hidden only while they last: once a problem is gone, its dismissal is
    /// forgotten, so the same problem shows again if it comes back. Problems that couldn't be checked
    /// this time (`unchecked` ID prefixes) keep their dismissal.
    static func pruneDismissed(_ dismissed: Set<String>, current: [Problem], unchecked: [String] = []) -> Set<String> {
        let ids = Set(current.map(\.id))
        return dismissed.filter { id in ids.contains(id) || unchecked.contains { id.hasPrefix($0) } }
    }

    /// Backup problems for guests (templates and guests with the ignore tag are skipped):
    /// not in any backup job, or covered but with no backup newer than `maxAgeDays` (0 turns that off).
    static func backupProblems(guests: [Guest], latest: [Int: Date], notCovered: Set<Int>?, maxAgeDays: Int,
                               ignoreTag: String, now: Date = Date()) -> [Problem] {
        let tag = ignoreTag.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Problem] = []
        for g in guests where !g.template && (tag.isEmpty || !g.tags.contains { $0.lowercased() == tag }) {
            let name = "\(g.displayName) (\(g.vmid))"
            if let notCovered, notCovered.contains(g.vmid) {
                out.append(Problem(kind: .backup, title: "\(name) is not in any backup job", detail: g.node, id: "backup-job-\(g.id)"))
                continue
            }
            guard maxAgeDays > 0 else { continue }
            if let last = latest[g.vmid] {
                let days = now.timeIntervalSince(last) / 86400
                if days > Double(maxAgeDays) {
                    out.append(Problem(kind: .backup, title: "\(name): last backup \(Int(days)) days ago",
                                       detail: Fmt.dateTime(last), id: "backup-age-\(g.id)"))
                }
            } else {
                out.append(Problem(kind: .backup, title: "\(name) has never been backed up", detail: g.node, id: "backup-none-\(g.id)"))
            }
        }
        return out
    }

    static func problems(unavailableStorage: [String], zfsPools: [String: [ZFSPool]], disks: [String: [NodeDisk]],
                         guests: [Guest], ceph: CephHealth?) -> [Problem] {
        var out: [Problem] = []
        for s in unavailableStorage {
            out.append(Problem(kind: .storageUnavailable, title: "Storage \(s) is not available", detail: "", id: "storage-down-\(s)"))
        }
        for (node, pools) in zfsPools.sorted(by: { $0.key < $1.key }) {
            for p in pools where !p.isHealthy {
                out.append(Problem(kind: .zfs, title: "ZFS pool \(p.name) on \(node) is \(p.health)", detail: "Check zpool status on the node",
                                   id: "zfs-\(node)-\(p.name)"))
            }
        }
        for (node, list) in disks.sorted(by: { $0.key < $1.key }) {
            for disk in list where disk.isFailing {
                out.append(Problem(kind: .disk, title: "Disk \(disk.devpath) on \(node) failed SMART (\(disk.health ?? ""))",
                                   detail: [disk.model, disk.serial].compactMap { $0 }.joined(separator: " · "), id: "disk-\(node)-\(disk.devpath)"))
            }
        }
        for g in guests where ["error", "fence"].contains(g.hastate ?? "") {
            out.append(Problem(kind: .ha, title: "HA: \(g.displayName) (\(g.vmid)) is in state \(g.hastate ?? "")", detail: g.node, id: "ha-\(g.id)"))
        }
        if let ceph, ceph.status != "HEALTH_OK", ceph.status != "UNKNOWN" {
            out.append(Problem(kind: .ceph, title: "Ceph: \(ceph.status)", detail: ceph.summaries.prefix(3).joined(separator: " · "), id: "ceph"))
        }
        return out
    }
}
