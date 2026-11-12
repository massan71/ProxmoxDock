import AppKit
import ServiceManagement

/// Open at login, via the system Login Items (SMAppService).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Showing or hiding the Dock icon. Hidden means the app lives only in the menu bar.
enum DockIcon {
    /// The Dock icon can only be hidden while the menu bar icon is shown,
    /// otherwise the app would have no visible way to be opened.
    static var shouldShow: Bool {
        let d = UserDefaults.standard
        let showDock = d.object(forKey: SettingsKey.showDockIcon) as? Bool ?? true
        let showMenuBar = d.object(forKey: SettingsKey.showMenuBar) as? Bool ?? true
        return showDock || !showMenuBar
    }

    @MainActor
    static func apply(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Changing the policy can send the app to the background; keep the open window in front
        NSApp.activate(ignoringOtherApps: true)
    }
}
