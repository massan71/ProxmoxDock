import AppKit
import SwiftUI

/// Copy, SSH and browser shortcuts for a guest's IP addresses.
enum GuestConnect {
    static func copy(_ ip: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    /// IPv6 addresses need brackets in URLs.
    static func host(_ ip: String) -> String { ip.contains(":") ? "[\(ip)]" : ip }

    /// Opens Terminal with "ssh user@ip" through the ssh:// URL handler.
    static func ssh(_ ip: String, user: String) {
        let who = user.trimmingCharacters(in: .whitespaces)
        let userPart = who.isEmpty ? "" : "\(who.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? who)@"
        if let url = URL(string: "ssh://\(userPart)\(host(ip))") { NSWorkspace.shared.open(url) }
    }

    static func browse(_ ip: String, https: Bool) {
        if let url = URL(string: "\(https ? "https" : "http")://\(host(ip))") { NSWorkspace.shared.open(url) }
    }
}

/// Context menu items for a guest's IPs (nothing when there are none).
struct GuestConnectMenu: View {
    let addresses: [String]
    let sshUser: String

    var body: some View {
        if addresses.count == 1, let ip = addresses.first {
            Button("Copy IP Address (\(ip))") { GuestConnect.copy(ip) }
            Button("SSH to \(ip)") { GuestConnect.ssh(ip, user: sshUser) }
            Button("Open http://\(GuestConnect.host(ip))") { GuestConnect.browse(ip, https: false) }
            Button("Open https://\(GuestConnect.host(ip))") { GuestConnect.browse(ip, https: true) }
        } else if addresses.count > 1 {
            Menu("Copy IP Address") { ForEach(addresses, id: \.self) { ip in Button(ip) { GuestConnect.copy(ip) } } }
            Menu("SSH") { ForEach(addresses, id: \.self) { ip in Button(ip) { GuestConnect.ssh(ip, user: sshUser) } } }
            Menu("Open in Browser") {
                ForEach(addresses, id: \.self) { ip in
                    Button("http://\(GuestConnect.host(ip))") { GuestConnect.browse(ip, https: false) }
                    Button("https://\(GuestConnect.host(ip))") { GuestConnect.browse(ip, https: true) }
                }
            }
        }
    }
}
