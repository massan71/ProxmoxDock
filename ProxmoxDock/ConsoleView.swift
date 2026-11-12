import AppKit
import SwiftUI
import WebKit

/// What a console window shows: a node's shell, a VM (noVNC) or a container (xterm.js).
struct ConsoleTarget: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case node, qemu, lxc }
    var kind: Kind
    var node: String
    var vmid: Int?
    var name: String

    var id: String { "\(kind.rawValue)/\(node)/\(vmid ?? 0)" }

    var title: String {
        switch kind {
        case .node: return "Shell – \(node)"
        case .qemu: return "\(name) (VM \(vmid ?? 0))"
        case .lxc: return "\(name) (CT \(vmid ?? 0))"
        }
    }

    static func node(_ name: String) -> ConsoleTarget { ConsoleTarget(kind: .node, node: name, vmid: nil, name: name) }
    static func guest(_ g: Guest) -> ConsoleTarget {
        ConsoleTarget(kind: g.kind == .qemu ? .qemu : .lxc, node: g.node, vmid: g.vmid, name: g.displayName)
    }

    /// The Proxmox web interface, where the user logs in to get a ticket.
    static func loginURL(base: String) -> URL? { URL(string: ProxmoxAPI.normalizedBase(base) + "/") }

    /// The Proxmox web interface's own console page, the one it opens in a new window.
    /// API tokens can't open consoles, so this page asks for a Proxmox login the first time.
    func url(base: String) -> URL? {
        var comps = URLComponents(string: ProxmoxAPI.normalizedBase(base) + "/")
        var q = [URLQueryItem(name: "node", value: node)]
        switch kind {
        case .node:
            q += [URLQueryItem(name: "console", value: "shell"), URLQueryItem(name: "xtermjs", value: "1")]
        case .qemu:
            q += [URLQueryItem(name: "console", value: "kvm"), URLQueryItem(name: "novnc", value: "1"),
                  URLQueryItem(name: "vmid", value: vmid.map(String.init)), URLQueryItem(name: "vmname", value: name),
                  URLQueryItem(name: "resize", value: "scale")]
        case .lxc:
            q += [URLQueryItem(name: "console", value: "lxc"), URLQueryItem(name: "xtermjs", value: "1"),
                  URLQueryItem(name: "vmid", value: vmid.map(String.init)), URLQueryItem(name: "vmname", value: name)]
        }
        comps?.queryItems = q
        return comps?.url
    }
}

/// A window with the console of a node, VM or container.
struct ConsoleWindow: View {
    let target: ConsoleTarget
    @EnvironmentObject var store: Store
    @StateObject private var model = ConsoleModel()

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.callout).textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(.orange.opacity(0.12))
            }
            if model.needsLogin {
                HStack(alignment: .top) {
                    Image(systemName: "person.badge.key.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log in with your Proxmox user to open the console (API tokens can't open consoles).")
                            .font(.callout)
                        Text("The console opens as soon as you're logged in, and the login is kept for about 2 hours. ProxmoxDock doesn't see or store your password.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.blue.opacity(0.10))
            }
            if let url = target.url(base: store.baseURL), let login = ConsoleTarget.loginURL(base: store.baseURL) {
                ConsoleWebView(consoleURL: url, loginURL: login, model: model)
            } else {
                ContentUnavailableView("Server not configured", systemImage: "server.rack",
                                       description: Text("Set the server URL in Settings."))
            }
        }
        .navigationTitle(target.title)
        .navigationSubtitle(model.isLoading ? "Loading…" : "")
        .toolbar {
            ToolbarItemGroup {
                Button { model.reload() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    .help("Reload the console")
                Button {
                    if let url = target.url(base: store.baseURL) { NSWorkspace.shared.open(url) }
                } label: { Label("Open in Browser", systemImage: "safari") }
                    .help("Open this console in your web browser")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// Opens the console once there is a valid Proxmox login ticket; otherwise shows the Proxmox
/// login page and switches to the console as soon as the ticket cookie appears.
@MainActor
final class ConsoleModel: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    @Published var isLoading = false
    @Published var problem: String?
    @Published var needsLogin = false
    weak var webView: WKWebView?
    var consoleURL: URL?
    var loginURL: URL?
    private var observing = false

    func start() {
        problem = nil
        Task { await route() }
    }

    func reload() { start() }

    private func route() async {
        guard let webView, let consoleURL, let loginURL else { return }
        let cookies = webView.configuration.websiteDataStore.httpCookieStore
        if await Self.hasValidTicket(cookies, host: consoleURL.host) {
            needsLogin = false
            stopObserving(cookies)
            webView.load(URLRequest(url: consoleURL))
        } else {
            needsLogin = true
            if !observing {
                cookies.add(self)
                observing = true
            }
            webView.load(URLRequest(url: loginURL))
        }
    }

    private func stopObserving(_ cookies: WKHTTPCookieStore) {
        guard observing else { return }
        cookies.remove(self)
        observing = false
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            guard needsLogin, let consoleURL, await Self.hasValidTicket(cookieStore, host: consoleURL.host) else { return }
            needsLogin = false
            stopObserving(cookieStore)
            webView?.load(URLRequest(url: consoleURL))
        }
    }

    /// Whether the store holds a Proxmox ticket for this host that hasn't expired.
    static func hasValidTicket(_ store: WKHTTPCookieStore, host: String?) async -> Bool {
        guard let host = host?.lowercased() else { return false }
        let cookies = await store.allCookies()
        guard let cookie = cookies.first(where: {
            $0.name == "PVEAuthCookie" && $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
        }) else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        return ticketIsFresh(cookie.value)
    }

    /// Proxmox tickets look like "PVE:user@realm:<hex creation time>::<signature>" and are valid
    /// for 2 hours. Unknown formats are left for the server to judge.
    nonisolated static func ticketIsFresh(_ raw: String, now: Date = Date()) -> Bool {
        let value = raw.removingPercentEncoding ?? raw
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "PVE", let created = UInt64(parts[2], radix: 16) else { return true }
        return now.timeIntervalSince1970 - Double(created) < 2 * 3600 - 120
    }
}

/// WKWebView that accepts the server's certificate only if macOS trusts it or it is the one
/// the user trusted in Settings (same rule as the API client). Cookies persist, so the
/// Proxmox login is remembered until its ticket expires.
struct ConsoleWebView: NSViewRepresentable {
    let consoleURL: URL
    let loginURL: URL
    let model: ConsoleModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsMagnification = true
        model.webView = view
        model.consoleURL = consoleURL
        model.loginURL = loginURL
        model.start()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: ConsoleModel
        init(model: ConsoleModel) { self.model = model }

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            if SecTrustEvaluateWithError(trust, nil) { return (.useCredential, URLCredential(trust: trust)) }
            let fingerprint = CertificateTrust.leafFingerprint(trust)
            if let fingerprint, fingerprint == CertificateTrust.shared.pinned {
                return (.useCredential, URLCredential(trust: trust))
            }
            await MainActor.run {
                model.problem = "The server's certificate isn't the one you trusted in Settings\(fingerprint.map { " (it presented \($0))" } ?? ""). Review it in Settings, then reconnect."
            }
            return (.cancelAuthenticationChallenge, nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in model.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in model.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let ns = error as NSError
            Task { @MainActor in
                model.isLoading = false
                // A refused certificate already set a clearer message
                if model.problem == nil, ns.code != NSURLErrorCancelled {
                    model.problem = "Could not load the console: \(error.localizedDescription)"
                }
            }
        }

        // Links that open a new window (e.g. help) go to the default browser
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }

        // Proxmox uses JavaScript confirm/alert dialogs in places
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}
