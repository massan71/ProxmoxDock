import SwiftUI

/// Icon (and optional problem count) in the macOS menu bar.
struct MenuBarLabel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let count = store.problems.count
        HStack(spacing: 3) {
            Image(systemName: count > 0 || (store.isConfigured && store.errorMessage != nil) ? "exclamationmark.triangle.fill" : "server.rack")
            if store.menuBarShowsCount && count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
    }
}

/// Compact panel with the essentials, opened from the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Proxmox").font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else if let last = store.lastUpdated {
                    Text("Updated \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
                }
                Button { store.manualRefresh(from: "menu bar") } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .disabled(store.isLoading || !store.isConfigured)
            }

            if !store.isConfigured {
                Text("Not configured. Open Settings to enter your server and API token.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if let err = store.errorMessage {
                    HStack(alignment: .top) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).lineLimit(3)
                        Spacer(minLength: 4)
                        Button { store.dismissError() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
                ForEach(store.nodes) { node in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(node.online ? .green : .red).frame(width: 8, height: 8)
                            Text(node.name)
                            Spacer()
                            Text(node.online ? "CPU \(Fmt.percent(node.cpu)) · RAM \(Fmt.percent(node.maxmem > 0 ? node.mem / node.maxmem : 0))" : "Offline")
                                .font(.caption).monospacedDigit().foregroundStyle(node.online ? Color.secondary : Color.red)
                        }
                    }
                }
                HStack(spacing: 8) {
                    MiniStat(value: "\(store.runningGuests.count)", title: "Running", tint: .primary)
                    MiniStat(value: "\(store.problems.count)", title: "Problems", tint: store.problems.isEmpty ? .green : .red)
                    MiniStat(value: "\(store.failedTasks.count)", title: "Failed tasks", tint: store.failedTasks.isEmpty ? .green : .red)
                }
                if !store.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.problems.prefix(5)) { p in
                            Label(p.title, systemImage: p.icon).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                }
                ForEach(store.tracked.filter { !$0.finished }) { t in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(t.title).font(.caption).lineLimit(1)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open ProxmoxDock") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit ProxmoxDock")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct MiniStat: View {
    let value: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
