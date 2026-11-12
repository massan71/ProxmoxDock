# ProxmoxDock

A macOS Dock and menu bar app to monitor and manage a [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment) server or cluster through its [REST API](https://pve.proxmox.com/wiki/Proxmox_VE_API).

> Independent project, not affiliated with or endorsed by Proxmox Server Solutions GmbH.

## Features

- **Dock icon badge** with the number of problems: offline nodes, lost quorum, failed tasks in the last 24 hours, storage above a threshold (90% by default) or unavailable, unhealthy ZFS pools, disks failing SMART, HA errors and Ceph warnings; `!` when the connection fails
- **Dock menu** and optional **menu bar icon** with node status, running guests, problems and tasks in progress; the Dock icon can be hidden to use the app only from the menu bar
- **Overview**: nodes online, running VMs/containers, problems, failed tasks, Ceph health, and per node CPU, memory, root disk, ZFS pools, SMART summary and available updates
- **VMs & Containers**: status, ID, name, type, node, CPU, memory, uptime and tags, with search and filters; right-click to **start, shut down, reboot or stop** a guest
- **Guest details** (double-click): power actions, **snapshots** (take, with or without RAM; roll back, optionally starting the guest; delete) and **backup now** (vzdump with zstd to a storage of your choice, snapshot/suspend/stop mode)
- **Consoles**: open a node's shell (xterm.js) or a VM (noVNC) or container (xterm.js) console in its own window — from the terminal button on a node, a guest's context menu or the guest details
- **Storage**: usage of every storage, shared storage listed once
- **Tasks**: tasks of the last 24 hours, with failed ones highlighted; tasks started from the app show their progress until they finish
- Notifications for failed tasks, nodes going offline and new health problems
- Automatic refresh (1–30 min, and right after the Mac wakes up or the network comes back); optional open at login
- Every action that changes something asks for confirmation first

## Install

With [Homebrew](https://brew.sh):

```bash
brew install --cask massan71/tap/proxmoxdock
```

Update with `brew upgrade --cask proxmoxdock`. Or download the zip from [Releases](https://github.com/massan71/ProxmoxDock/releases/latest) and move `ProxmoxDock.app` to `/Applications`.

The app is ad-hoc signed and not notarized. The Homebrew cask removes the quarantine flag so it opens directly; with the zip, macOS blocks the first launch until you click **Open Anyway** in System Settings → Privacy & Security.

Requires macOS 14 or later (universal: Apple silicon and Intel) and Proxmox VE with API tokens (6.2 or later).

## Setup

1. In the Proxmox web interface: **Datacenter → Permissions → API Tokens → Add**. Note the token ID (e.g. `root@pam!proxmoxdock`) and the secret, which is shown only once.
2. With *Privilege Separation* on (the default), give the token permissions under **Permissions → Add → API Token Permission**:
   - viewing: **PVEAuditor** on `/`
   - power actions: **VM.PowerMgmt**; snapshots: **VM.Snapshot** (and **VM.Snapshot.Rollback**); backups: **VM.Backup** plus **Datastore.AllocateSpace** on the backup storage — for example the **PVEVMAdmin** role on `/vms` and **PVEDatastoreUser** on the backup storage
3. In ProxmoxDock open **Settings** (⌘,), enter the server URL (port 8006 is added if missing), token ID and secret, then click **Save and Test**.
4. Allow ProxmoxDock to access the local network when macOS asks.

### Health checks

On every refresh ProxmoxDock checks storage availability, ZFS pool health (`zpool` state other than ONLINE), HA resources in error and, when the cluster uses Ceph storage, Ceph health. Every hour it also checks the disks' SMART status and the list of available updates; both can be turned off in **Settings → Health Checks** (Proxmox queries every disk for SMART, which can wake hard disks from standby). Available updates are shown as a notice, or counted as a problem if you choose so; reading them needs **Sys.Modify** on `/nodes`, which PVEAuditor doesn't include — without it the rest works and Settings says what's missing.

### Consoles

Proxmox doesn't allow API tokens to open consoles, so the console window shows the Proxmox login page the first time: log in with your Proxmox user (for example `root`, realm *Linux PAM*) and the console opens right after. The login ticket is kept for about two hours, so later consoles open directly. The password is handled by the Proxmox page itself; ProxmoxDock never sees or stores it. The user needs the console privileges (**VM.Console** for guests, **Sys.Console** for node shells). Each console window also has **Open in Browser**.

### Certificates

Proxmox uses a self-signed certificate by default. ProxmoxDock accepts certificates that macOS trusts (e.g. Let's Encrypt); for any other certificate it shows the SHA-256 fingerprint in Settings so you can compare it with the one in the Proxmox web interface (node → System → Certificates, `pve-ssl.pem`) before clicking **Trust This Certificate**. Only that exact certificate is then accepted — by the API client and by console windows — and if it changes, you're asked again. The token is only ever sent over HTTPS, and the secret is stored in the Keychain.

## Building

```bash
git clone https://github.com/massan71/ProxmoxDock.git
cd ProxmoxDock
open ProxmoxDock.xcodeproj
```

Then press ⌘R in Xcode. From the command line:

```bash
xcodebuild -project ProxmoxDock.xcodeproj -scheme ProxmoxDock -configuration Release -derivedDataPath build/DerivedData build
```

### Publishing a release

```bash
scripts/release.sh 1.1 notes.md
```

Sets the version, builds a clean universal Release, zips and verifies it, then asks for confirmation before committing, tagging, pushing and creating the GitHub release. If [massan71/homebrew-tap](https://github.com/massan71/homebrew-tap) is checked out next to this repository, its cask is updated and pushed too.

## Project structure

| File | Contents |
|---|---|
| `ProxmoxDock/ProxmoxAPI.swift` | API client (token auth, certificate pinning) for cluster resources, status, tasks, power, snapshots and backups |
| `ProxmoxDock/Models.swift` | Data models with lenient decoding, formatting |
| `ProxmoxDock/Store.swift` | State, refresh loop, problems and Dock badge, notifications, task tracking |
| `ProxmoxDock/Health.swift` | Health rules: storage, ZFS, SMART, HA and Ceph problems |
| `ProxmoxDock/Views.swift` | Main window: overview, guests, storage, tasks |
| `ProxmoxDock/GuestDetailView.swift` | Power, snapshots and backup for one guest |
| `ProxmoxDock/SettingsView.swift` | Settings, including certificate review |
| `ProxmoxDock/ConsoleView.swift` | Console windows: login when needed, then noVNC or xterm.js |
| `ProxmoxDock/MenuBarView.swift` | Menu bar icon and panel |
| `ProxmoxDock/App.swift` | Entry point and Dock menu |
| `ProxmoxDock/AppPresence.swift` | Open at login and Dock icon visibility |
| `ProxmoxDock/Keychain.swift` | Keychain storage for the token secret |

## License

Released under the [MIT](LICENSE) license.
