// Hop — a menu-bar launcher for connecting to remote Macs.
// Screen Sharing (vnc://), SSH in Terminal (ssh://), shared files (smb://),
// Wake-on-LAN, a live online/offline indicator, and automatic discovery of
// the Macs on your Tailscale network (tailnet).
// Requires macOS 13+. Build with ./build.sh
//
// Open source (MIT) — https://github.com/sercanatalik/hop-remote-launcher

import SwiftUI
import AppKit
import Network
import ServiceManagement

// MARK: - Model

struct RemoteMac: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Mac"
    var host: String = ""      // hostname, Bonjour name (studio.local), IP, or Tailscale name
    var user: String = ""      // optional account name on the remote Mac
    var mac: String = ""       // optional MAC address for Wake-on-LAN (aa:bb:cc:dd:ee:ff)
    var isTailnet = false      // discovered from Tailscale (not saved)

    enum CodingKeys: String, CodingKey { case id, name, host, user, mac }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Mac"
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        mac  = (try? c.decode(String.self, forKey: .mac)) ?? ""
    }
}

// MARK: - Tailscale

enum TailscaleState: Equatable {
    case unknown
    case notInstalled
    case notRunning(String)
    case running
}

struct TailscalePeer {
    let name: String
    let host: String
    let os: String
    let online: Bool
    let ips: [String]
}

enum Tailscale {
    /// Where the Tailscale CLI lives: inside the Mac app (App Store or standalone), or Homebrew.
    static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func cliPath() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct Status: Decodable {
        let BackendState: String?
        let Peer: [String: Peer]?
        struct Peer: Decodable {
            let HostName: String?
            let DNSName: String?
            let OS: String?
            let Online: Bool?
            let TailscaleIPs: [String]?
        }
    }

    /// Runs `tailscale status --json` and returns every peer on the tailnet.
    static func fetch() async -> (TailscaleState, [TailscalePeer]) {
        guard let path = cliPath() else { return (.notInstalled, []) }
        return await Task.detached(priority: .utility) { () -> (TailscaleState, [TailscalePeer]) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["status", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (.notRunning("Couldn't run Tailscale"), []) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            guard let s = try? JSONDecoder().decode(Status.self, from: data) else {
                return (.notRunning("Tailscale isn't running"), [])
            }
            guard s.BackendState == "Running" else {
                let state = s.BackendState ?? "Stopped"
                return (.notRunning(state == "NeedsLogin" ? "Sign in to Tailscale" : "Tailscale is \(state.lowercased())"), [])
            }
            let peers = (s.Peer ?? [:]).values.map { pr -> TailscalePeer in
                let dns = (pr.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let ip = pr.TailscaleIPs?.first ?? ""
                return TailscalePeer(name: pr.HostName ?? dns,
                                     host: dns.isEmpty ? ip : dns,
                                     os: pr.OS ?? "",
                                     online: pr.Online ?? false,
                                     ips: pr.TailscaleIPs ?? [])
            }
            .filter { !$0.host.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return (.running, peers)
        }.value
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var hosts: [RemoteMac] = [] { didSet { save() } }
    @Published var online: [UUID: Bool] = [:]

    @Published var tailnet: [RemoteMac] = []
    @Published var tailscaleState: TailscaleState = .unknown
    @Published var showTailscale: Bool = UserDefaults.standard.object(forKey: "showTailscale") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTailscale, forKey: "showTailscale"); refreshTailscale() }
    }
    @Published var tailscaleMacsOnly: Bool = UserDefaults.standard.object(forKey: "tailscaleMacsOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tailscaleMacsOnly, forKey: "tailscaleMacsOnly"); refreshTailscale() }
    }

    private let fileURL: URL
    private var timer: Timer?
    private var loading = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("hosts.json")
        // Carry over the list saved by the earlier build (when the app was called MacLauncher).
        let old = dir.deletingLastPathComponent().appendingPathComponent("MacLauncher/hosts.json")
        if !FileManager.default.fileExists(atPath: fileURL.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: fileURL)
        }
        load()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var configURL: URL { fileURL }
    var onlineCount: Int { (hosts + tailnet).filter { online[$0.id] == true }.count }
    var totalCount: Int { hosts.count + tailnet.count }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([RemoteMac].self, from: data) else { return }
        hosts = list
    }

    func save() {
        guard !loading else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(hosts) { try? data.write(to: fileURL, options: .atomic) }
    }

    func refresh() {
        for m in hosts where !m.host.trimmingCharacters(in: .whitespaces).isEmpty {
            let id = m.id, host = m.host.trimmingCharacters(in: .whitespaces)
            Task {
                async let vnc = Probe.tcp(host: host, port: 5900)
                async let ssh = Probe.tcp(host: host, port: 22)
                let a = await vnc
                let b = await ssh
                self.online[id] = a || b
            }
        }
        refreshTailscale()
    }

    func refreshTailscale() {
        guard showTailscale else {
            tailnet = []
            tailscaleState = .unknown
            return
        }
        Task {
            let (state, peers) = await Tailscale.fetch()
            // Skip peers you've already saved under "My Macs".
            let saved = Set(hosts.map { $0.host.lowercased().trimmingCharacters(in: .whitespaces) })
            let oldIDs = Dictionary(tailnet.map { ($0.host, $0.id) }, uniquingKeysWith: { a, _ in a })
            var list: [RemoteMac] = []
            for p in peers {
                if tailscaleMacsOnly && p.os != "macOS" { continue }
                let full = p.host.lowercased()
                let short = full.split(separator: ".").first.map(String.init) ?? full
                if saved.contains(full) || saved.contains(short) || p.ips.contains(where: { saved.contains($0) }) { continue }
                var m = RemoteMac()
                m.id = oldIDs[p.host] ?? UUID()
                m.name = p.name
                m.host = p.host
                m.isTailnet = true
                list.append(m)
                online[m.id] = p.online
            }
            tailscaleState = state
            tailnet = list
        }
    }

    func dot(_ m: RemoteMac) -> String {
        switch online[m.id] {
        case .some(true):  return "🟢"
        case .some(false): return "⚫️"
        case .none:        return "⚪️"
        }
    }

    func isSaved(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return hosts.contains { $0.id == id }
    }

    func add() -> UUID {
        let m = RemoteMac()
        hosts.append(m)
        return m.id
    }

    /// Copies a Tailscale device into "My Macs" so you can rename it, set a user, etc.
    @discardableResult
    func pin(_ m: RemoteMac) -> UUID {
        var c = m
        c.id = UUID()
        c.isTailnet = false
        hosts.append(c)
        online[c.id] = online[m.id]
        tailnet.removeAll { $0.id == m.id }
        return c.id
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        online[id] = nil
        refreshTailscale()
    }
}

// MARK: - Reachability probe

private final class Once: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

enum Probe {
    static func tcp(host: String, port: UInt16, timeout: Double = 2.5) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

// MARK: - App info

enum HopInfo {
    static let repoURL = URL(string: "https://github.com/sercanatalik/hop-remote-launcher")!
    static let issuesURL = URL(string: "https://github.com/sercanatalik/hop-remote-launcher/issues/new")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Actions

enum Actions {
    static func url(_ scheme: String, _ m: RemoteMac) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = m.host.trimmingCharacters(in: .whitespaces)
        let u = m.user.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { c.user = u }
        return c.url
    }

    static func open(_ scheme: String, _ m: RemoteMac) {
        guard !m.host.isEmpty, let u = url(scheme, m) else { NSSound.beep(); return }
        NSWorkspace.shared.open(u)
    }

    static func screenShare(_ m: RemoteMac) { open("vnc", m) }
    static func ssh(_ m: RemoteMac)         { open("ssh", m) }
    static func files(_ m: RemoteMac)       { open("smb", m) }

    static func copyAddress(_ m: RemoteMac) {
        let s = m.user.isEmpty ? m.host : "\(m.user)@\(m.host)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func openScreenSharingApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSharing") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        }
    }

    static func openTailscale() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else if let u = URL(string: "https://tailscale.com/download/mac") {
            NSWorkspace.shared.open(u)
        }
    }

    static func openGitHub() { NSWorkspace.shared.open(HopInfo.repoURL) }
    static func reportIssue() { NSWorkspace.shared.open(HopInfo.issuesURL) }

    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Open source under the MIT licence.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/sercanatalik/hop-remote-launcher",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: HopInfo.repoURL]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Sends a Wake-on-LAN magic packet to the local broadcast address (UDP port 9).
    @discardableResult
    static func wake(_ m: RemoteMac) -> Bool {
        let bytes = m.mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { NSSound.beep(); return false }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        addr.sin_addr.s_addr = 0xFFFF_FFFF   // 255.255.255.255

        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }
}

// MARK: - Menu bar menu

struct HostMenu: View {
    let m: RemoteMac
    @EnvironmentObject var store: Store

    var body: some View {
        Menu("\(store.dot(m))  \(m.name)") {
            Button("Screen Share") { Actions.screenShare(m) }
            Button("SSH in Terminal") { Actions.ssh(m) }
            Button("Open Shared Files") { Actions.files(m) }
            if !m.mac.isEmpty {
                Button("Wake (Wake-on-LAN)") { Actions.wake(m) }
            }
            Divider()
            Button("Copy Address") { Actions.copyAddress(m) }
            if m.isTailnet {
                Button("Add to My Macs") { store.pin(m) }
            }
            Text(m.user.isEmpty ? m.host : "\(m.user)@\(m.host)")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(store.onlineCount) of \(store.totalCount) online")

        Section("My Macs") {
            if store.hosts.isEmpty {
                Text("No saved Macs yet")
            }
            ForEach(store.hosts) { m in HostMenu(m: m) }
        }

        if store.showTailscale {
            Section("Tailscale") {
                switch store.tailscaleState {
                case .running:
                    if store.tailnet.isEmpty {
                        Text(store.tailscaleMacsOnly ? "No other Macs on your tailnet" : "No other devices on your tailnet")
                    }
                    ForEach(store.tailnet) { m in HostMenu(m: m) }
                case .notInstalled:
                    Button("Install Tailscale…") { Actions.openTailscale() }
                case .notRunning(let msg):
                    Button("\(msg) — Open Tailscale") { Actions.openTailscale() }
                case .unknown:
                    Text("Checking Tailscale…")
                }
            }
        }

        Divider()
        Button("Refresh Status") { store.refresh() }
            .keyboardShortcut("r")
        Button("Manage Macs…") {
            openWindow(id: "manager")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Button("Open Screen Sharing") { Actions.openScreenSharingApp() }
        Divider()
        Button("Hop on GitHub") { Actions.openGitHub() }
        Button("Report an Issue…") { Actions.reportIssue() }
        Button("About Hop \(HopInfo.version)") { Actions.showAbout() }
        Divider()
        Button("Quit Hop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Manager window

struct ManagerView: View {
    @EnvironmentObject var store: Store
    @State private var selection: UUID?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private func row(_ m: RemoteMac) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(store.dot(m))  \(m.name)")
            Text(m.host.isEmpty ? "No host set" : m.host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .tag(m.id)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("My Macs") {
                    ForEach(store.hosts) { m in row(m) }
                }
                if store.showTailscale {
                    Section("Tailscale") {
                        switch store.tailscaleState {
                        case .running:
                            ForEach(store.tailnet) { m in row(m) }
                            if store.tailnet.isEmpty {
                                Text("Nothing new on your tailnet").foregroundStyle(.secondary)
                            }
                        case .notInstalled:
                            Button("Install Tailscale…") { Actions.openTailscale() }
                        case .notRunning(let msg):
                            Button(msg) { Actions.openTailscale() }
                        case .unknown:
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Button { selection = store.add() } label: { Image(systemName: "plus") }
                        .help("Add a Mac")
                    Button {
                        if let id = selection, store.isSaved(id) { selection = nil; store.remove(id) }
                    } label: { Image(systemName: "minus") }
                    .disabled(!store.isSaved(selection))
                    .help("Remove from My Macs")
                    Spacer()
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh status and Tailscale devices")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = selection, let i = store.hosts.firstIndex(where: { $0.id == id }) {
                Form {
                    Section("Remote Mac") {
                        TextField("Name", text: $store.hosts[i].name)
                        TextField("Host", text: $store.hosts[i].host, prompt: Text("studio.local, 192.168.1.20, or Tailscale name"))
                        TextField("User", text: $store.hosts[i].user, prompt: Text("optional"))
                        TextField("MAC address", text: $store.hosts[i].mac, prompt: Text("optional, for Wake-on-LAN"))
                    }
                    Section { actions(store.hosts[i]) }
                }
                .formStyle(.grouped)
            } else if let id = selection, let m = store.tailnet.first(where: { $0.id == id }) {
                Form {
                    Section {
                        LabeledContent("Name", value: m.name)
                        LabeledContent("Tailscale address", value: m.host)
                        LabeledContent("Status", value: store.online[m.id] == true ? "Online" : "Offline")
                    } header: {
                        Text("From Tailscale")
                    } footer: {
                        Text("Add it to My Macs to rename it or set a user name.")
                    }
                    Section {
                        HStack {
                            actions(m)
                            Spacer()
                            Button("Add to My Macs") { selection = store.pin(m) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Select a Mac, or press + to add one")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Toggle("Show Tailscale devices", isOn: $store.showTailscale)
                    Toggle("Only Macs", isOn: $store.tailscaleMacsOnly)
                    Divider()
                    Button("Open Tailscale") { Actions.openTailscale() }
                } label: {
                    Label("Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            ToolbarItem {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else  { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            ToolbarItem {
                Button("Show Config File") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                }
            }
        }
        .frame(minWidth: 680, minHeight: 380)
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private func actions(_ m: RemoteMac) -> some View {
        HStack {
            Button("Screen Share") { Actions.screenShare(m) }
            Button("SSH") { Actions.ssh(m) }
            Button("Files") { Actions.files(m) }
            if !m.mac.isEmpty {
                Button("Wake") { Actions.wake(m) }
            }
        }
    }
}

// MARK: - Menu-bar glyph (a dotted hop landing on a laptop)

enum HopGlyph {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // take-off point
            NSBezierPath(ovalIn: NSRect(x: 1.5, y: 12.3, width: 3.4, height: 3.4)).fill()
            // dotted jump
            let arc = NSBezierPath()
            arc.move(to: NSPoint(x: 3.2, y: 10.8))
            arc.curve(to: NSPoint(x: 12.2, y: 7.4), controlPoint1: NSPoint(x: 4, y: 5), controlPoint2: NSPoint(x: 10.5, y: 3.5))
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            let dash: [CGFloat] = [0.01, 2.7]
            arc.setLineDash(dash, count: 2, phase: 0)
            arc.stroke()
            // laptop
            let screen = NSBezierPath(roundedRect: NSRect(x: 9.2, y: 8.6, width: 7.4, height: 5), xRadius: 1.1, yRadius: 1.1)
            screen.lineWidth = 1.4
            screen.stroke()
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 8.2, y: 15.8))
            base.line(to: NSPoint(x: 17.6, y: 15.8))
            base.lineWidth = 1.4
            base.lineCapStyle = .round
            base.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Hop"
        return img
    }()
}

// MARK: - App

@main
struct HopApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            Image(nsImage: HopGlyph.image)
        }
        .menuBarExtraStyle(.menu)

        Window("Manage Macs", id: "manager") {
            ManagerView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}
