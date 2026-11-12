import AppKit
import SwiftUI

@main
struct ProxmoxDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// The App must not observe the Store: every refresh would rebuild all scenes and
    /// overflow the stack (seen in FirewallaDock). Views observe it via environmentObject.
    private let store = Store.shared
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true

    var body: some Scene {
        Window("Proxmox", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { store.manualRefresh(from: "menu command") }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !DockIcon.shouldShow { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in Store.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the Dock / menu bar and keep updating the badge
    }

    /// Menu shown when right-clicking the Dock icon.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let store = Store.shared
        let menu = NSMenu()

        func info(_ title: String, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        if !store.isConfigured {
            info("Not configured: open Settings")
            return menu
        }
        for node in store.nodes {
            info("\(node.name) · \(node.online ? "online" : "OFFLINE")", node.online ? "checkmark.circle" : "xmark.octagon")
        }
        if !store.nodes.isEmpty { menu.addItem(.separator()) }
        info("Running: \(store.runningGuests.count) VMs/CTs", "play.circle")
        info("Problems: \(store.problems.count)", "exclamationmark.triangle")
        for p in store.problems.prefix(5) { info(p.title, p.icon) }
        if let last = store.lastUpdated {
            menu.addItem(.separator())
            info("Updated \(Fmt.relative(last))")
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        return menu
    }

    @objc func refreshNow() {
        Task { @MainActor in Store.shared.manualRefresh(from: "Dock menu") }
    }
}
