// Hop — a menu-bar launcher for connecting to remote Macs.
// Screen Sharing (vnc://), SSH in Terminal (ssh://), shared files (smb://),
// Wake-on-LAN, a live online/offline indicator, automatic discovery of
// the Macs on your Tailscale network (tailnet), and Herdr workspaces and
// agent status on those Macs.
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

// MARK: - Process runner

struct ShellResult {
    let out: Data
    let status: Int32
    let timedOut: Bool
    var ok: Bool { status == 0 && !timedOut }
}

enum Shell {
    /// Runs a tool off the main actor and returns its stdout. The child is terminated after `timeout` seconds.
    static func run(_ path: String, _ args: [String], timeout: Double) async -> ShellResult? {
        await Task.detached(priority: .utility) { () -> ShellResult? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let once = Once()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning, once.claim() { p.terminate() }
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let timedOut = !once.claim()   // already claimed means the timer fired
            return ShellResult(out: data, status: p.terminationStatus, timedOut: timedOut)
        }.value
    }
}

// MARK: - Herdr
//
// Herdr (https://herdr.dev) runs coding agents in workspaces ("spaces") on this Mac and on
// remote machines. Hop drives it through its command-line tools, the same way it uses Tailscale:
//   hc machine ls --json        the machines the desktop app knows (name, ssh target, state)
//   herdr-app ls                spaces, tabs and terminals, each terminal with an agent status
//   herdr-app do <command> ...  space.select / tab.new / space.new
//   herdr --remote <target>     the terminal app, attached to a remote machine
//
// Observed with Herdr desktop 0.1.x and herdr 0.9.5:
//   `herdr-app do space.select --id <id>` prints {"ok": true} and exits 0;
//   an unknown id prints {"error": "no such space"} and exits 1.
//   `hc machine ls` and `herdr-app ls` answer from local state in about 10 ms.
//   `herdr --remote user@host` goes straight to SSH for a host that is not a saved machine.
//   With the desktop app quit, `herdr-app ls`, `status` and `do` all fail at once with exit 2
//   ("no Herdr window ... Connection refused") and do not start the app. After launching it,
//   the CLI answers within about a second; remote spaces can take a little longer to appear,
//   which is why an action on a fresh launch is retried. The window alone cannot be closed
//   from outside, so "window closed, app running" is treated the same as any refusal.

enum AgentState: String, CaseIterable {
    case working, blocked, done, idle

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .blocked: return "diamond.fill"
        case .done:    return "checkmark"
        case .idle:    return "circle"
        }
    }
    var color: Color {
        switch self {
        case .working: return .accentColor
        case .blocked: return .orange
        case .done:    return .green
        case .idle:    return .secondary
        }
    }
}

struct HerdrAgent: Hashable {
    let tab: String
    let app: String
    let state: AgentState
}

struct HerdrSpace: Identifiable, Hashable {
    let id: String        // opaque, machine-prefixed; always passed back verbatim
    let name: String
    let folder: String
    let machine: String
    let tabCount: Int
    let agents: [HerdrAgent]   // terminals that run an agent; plain shells are left out

    var blocked: Int { agents.filter { $0.state == .blocked }.count }
}

struct HerdrMachine: Hashable {
    let name: String
    let target: String    // how SSH reaches it, usually user@host
    let host: String
    let state: String
}

struct HerdrBanner: Identifiable {
    let space: HerdrSpace
    let macName: String
    var id: String { space.id }
}

enum Herdr {
    static let bundleID = "dev.herdr.app"
    private static let home = NSHomeDirectory()

    static let appCandidates = [
        home + "/Applications/Herdr.app/Contents/MacOS/Herdr",
        "/Applications/Herdr.app/Contents/MacOS/Herdr",
        home + "/.local/bin/herdr-app",
    ]
    static let coreCandidates = [home + "/.local/bin/hc", "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
    static let terminalCandidates = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", home + "/.local/bin/herdr"]

    private static func first(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// The desktop app's own executable, which doubles as its CLI.
    static func appCLI() -> String? { first(appCandidates) }
    static func coreCLI() -> String? { first(coreCandidates) }
    static func terminalCLI() -> String? { first(terminalCandidates) }

    // MARK: Decoding (every field optional; anything unexpected means "no Herdr information")

    private struct MachineList: Decodable {
        let machines: [M]?
        struct M: Decodable { let name: String?; let target: String?; let host: String?; let state: String? }
    }
    private struct SpaceList: Decodable {
        let spaces: [S]?
        struct S: Decodable { let id: String?; let name: String?; let folder: String?; let machine: String?; let tabs: [T]? }
        struct T: Decodable { let name: String?; let terminals: [Term]? }
        struct Term: Decodable { let status: String?; let app: String? }
    }

    static func decodeMachines(_ data: Data) -> [HerdrMachine] {
        guard let list = try? JSONDecoder().decode(MachineList.self, from: data) else { return [] }
        return (list.machines ?? []).compactMap { m in
            guard let name = m.name, !name.isEmpty else { return nil }
            return HerdrMachine(name: name, target: m.target ?? "", host: m.host ?? "", state: m.state ?? "")
        }
    }

    /// Spaces grouped by machine name, in Herdr's order. Spaces on this computer (no machine) are left out.
    static func decodeSpaces(_ data: Data) -> [String: [HerdrSpace]] {
        guard let list = try? JSONDecoder().decode(SpaceList.self, from: data) else { return [:] }
        var out: [String: [HerdrSpace]] = [:]
        for s in list.spaces ?? [] {
            guard let id = s.id, !id.isEmpty, let machine = s.machine, !machine.isEmpty else { continue }
            let folder = s.folder ?? ""
            var name = s.name ?? ""
            if name.isEmpty { name = URL(fileURLWithPath: folder).lastPathComponent }
            if name.isEmpty { name = "Untitled" }
            var agents: [HerdrAgent] = []
            for (i, t) in (s.tabs ?? []).enumerated() {
                let tab = (t.name?.isEmpty == false) ? t.name! : String(i + 1)
                for term in t.terminals ?? [] {
                    guard let raw = term.status, let state = AgentState(rawValue: raw) else { continue }
                    agents.append(HerdrAgent(tab: tab, app: term.app ?? "agent", state: state))
                }
            }
            out[machine, default: []].append(
                HerdrSpace(id: id, name: name, folder: folder, machine: machine, tabCount: s.tabs?.count ?? 0, agents: agents))
        }
        return out
    }

    static func fetch() async -> (machines: [HerdrMachine], spaces: [String: [HerdrSpace]]) {
        guard let app = appCLI() else { return ([], [:]) }
        var machines: [HerdrMachine] = []
        if let hc = coreCLI(), let r = await Shell.run(hc, ["machine", "ls", "--json"], timeout: 3), r.ok {
            machines = decodeMachines(r.out)
        }
        var spaces: [String: [HerdrSpace]] = [:]
        if let r = await Shell.run(app, ["ls"], timeout: 3), r.ok {
            spaces = decodeSpaces(r.out)
        }
        return (machines, spaces)
    }

    // MARK: Pure helpers

    /// The host part of an SSH target: no user name, lower case.
    static func hostPart(_ target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces).lowercased()
        return t.split(separator: "@").last.map(String.init) ?? t
    }

    private static func firstLabel(_ host: String) -> String? {
        // An IP address has no meaningful first label.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") { return nil }
        return host.split(separator: ".").first.map(String.init)
    }

    /// A Mac is this Herdr machine when the two host names are equal, or one is the first label of the other.
    static func matches(_ machine: HerdrMachine, host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty else { return false }
        for cand in [hostPart(machine.target), machine.host.trimmingCharacters(in: .whitespaces).lowercased()] where !cand.isEmpty {
            if cand == h || firstLabel(h) == cand || firstLabel(cand) == h { return true }
        }
        return false
    }

    /// "1 working, 1 done": counts in a fixed order, zero counts left out. Empty when there are no agents.
    static func summary(_ agents: [HerdrAgent]) -> String {
        AgentState.allCases.compactMap { state in
            let n = agents.filter { $0.state == state }.count
            return n > 0 ? "\(n) \(state.rawValue)" : nil
        }.joined(separator: ", ")
    }

    /// The most urgent state present, used to pick one glyph for a space.
    static func leading(_ agents: [HerdrAgent]) -> AgentState? {
        [AgentState.blocked, .working, .done, .idle].first { s in agents.contains { $0.state == s } }
    }

    /// The spaces with a blocked agent: the first `limit`, and how many more there are.
    static func banners(_ all: [HerdrBanner], limit: Int = 3) -> (shown: [HerdrBanner], more: Int) {
        let waiting = all.filter { $0.space.blocked > 0 }
        return (Array(waiting.prefix(limit)), max(0, waiting.count - limit))
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Agent status mode

enum AgentStatusMode: Equatable {
    case on
    case muted(until: Date)
    case off

    static let eightHours: TimeInterval = 8 * 3600
    static let oneWeek: TimeInterval = 7 * 86400

    /// An expired mute counts as on.
    func resolved(at now: Date) -> AgentStatusMode {
        if case .muted(let until) = self, until <= now { return .on }
        return self
    }

    var shows: Bool { self == .on }

    /// Without the end time, for places with little room.
    var shortLabel: String {
        switch self {
        case .on:    return "On"
        case .off:   return "Off"
        case .muted: return "Muted"
        }
    }

    var label: String {
        switch self {
        case .on:  return "On"
        case .off: return "Off"
        case .muted(let until):
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("EEEjmm")
            return "Muted until \(f.string(from: until))"
        }
    }

    static func load(from d: UserDefaults = .standard, now: Date = Date()) -> AgentStatusMode {
        switch d.string(forKey: "agentStatus") {
        case "off": return .off
        case "muted":
            guard let until = d.object(forKey: "agentStatusMuteUntil") as? Date else { return .on }
            return AgentStatusMode.muted(until: until).resolved(at: now)
        default: return .on
        }
    }

    func save(to d: UserDefaults = .standard) {
        switch self {
        case .on:
            d.set("on", forKey: "agentStatus"); d.removeObject(forKey: "agentStatusMuteUntil")
        case .off:
            d.set("off", forKey: "agentStatus"); d.removeObject(forKey: "agentStatusMuteUntil")
        case .muted(let until):
            d.set("muted", forKey: "agentStatus"); d.set(until, forKey: "agentStatusMuteUntil")
        }
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

    // Herdr
    @Published var herdrAppInstalled = false
    @Published var herdrTerminalInstalled = false
    @Published var herdrMachines: [HerdrMachine] = []
    @Published var herdrSpaces: [String: [HerdrSpace]] = [:]
    @Published var agentMode: AgentStatusMode = AgentStatusMode.load() { didSet { agentMode.save() } }

    private let fileURL: URL
    private var timer: Timer?
    private var loading = false

    nonisolated static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hop", isDirectory: true)
    }

    init() {
        let dir = Store.supportDir
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
        refreshHerdr()
    }

    // MARK: Herdr

    func refreshHerdr() {
        herdrAppInstalled = Herdr.appCLI() != nil
        herdrTerminalInstalled = Herdr.terminalCLI() != nil
        let resolved = agentMode.resolved(at: Date())
        if resolved != agentMode { agentMode = resolved }   // a mute that has run out
        guard herdrAppInstalled else {
            herdrMachines = []
            herdrSpaces = [:]
            return
        }
        Task {
            let (machines, spaces) = await Herdr.fetch()
            herdrMachines = machines
            herdrSpaces = spaces
        }
    }

    /// Refreshes Herdr a moment after an action, once Herdr has settled.
    func refreshHerdrSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            refreshHerdr()
        }
    }

    var showAgentStatus: Bool { agentMode.resolved(at: Date()).shows }

    func mute(for seconds: TimeInterval) { agentMode = .muted(until: Date().addingTimeInterval(seconds)) }

    func mac(_ id: UUID?) -> RemoteMac? {
        guard let id else { return nil }
        return (hosts + tailnet).first { $0.id == id }
    }

    func machine(for m: RemoteMac) -> HerdrMachine? {
        guard herdrAppInstalled else { return nil }
        return herdrMachines.first { Herdr.matches($0, host: m.host) }
    }

    func spaces(for m: RemoteMac) -> [HerdrSpace] {
        guard let machine = machine(for: m) else { return [] }
        return herdrSpaces[machine.name] ?? []
    }

    func blocked(for m: RemoteMac) -> Int {
        showAgentStatus ? spaces(for: m).reduce(0) { $0 + $1.blocked } : 0
    }

    /// Every space on a matched Mac, once each, in Mac then Herdr order.
    private var listedSpaces: [HerdrBanner] {
        var seen = Set<String>()
        var out: [HerdrBanner] = []
        for m in hosts + tailnet {
            guard let machine = machine(for: m), seen.insert(machine.name).inserted else { continue }
            out += (herdrSpaces[machine.name] ?? []).map { HerdrBanner(space: $0, macName: m.name) }
        }
        return out
    }

    var totalBlocked: Int {
        showAgentStatus ? listedSpaces.reduce(0) { $0 + $1.space.blocked } : 0
    }

    var banners: (shown: [HerdrBanner], more: Int) {
        showAgentStatus ? Herdr.banners(listedSpaces) : ([], 0)
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

    // MARK: Herdr

    /// Runs a Herdr desktop command, starting the app first if it isn't running, then brings Herdr forward.
    @MainActor
    static func herdr(_ args: [String], store: Store) {
        guard let cli = Herdr.appCLI() else { NSSound.beep(); return }
        Task { @MainActor in
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Herdr.bundleID).isEmpty
            if !wasRunning { activateHerdr() }
            // A fresh launch needs a moment before it answers; a running app gets one attempt.
            let deadline = Date().addingTimeInterval(wasRunning ? 0 : 10)
            var ok = false
            while true {
                let r = await Shell.run(cli, ["do"] + args, timeout: 10)
                if let r, r.ok { ok = true; break }
                // Never repeat a command that may have run: stop on a timeout, retry only a quick refusal.
                if r?.timedOut == true || Date() >= deadline { break }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if ok {
                activateHerdr()
                store.refreshHerdrSoon()
            } else {
                NSSound.beep()
            }
        }
    }

    static func activateHerdr() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Herdr.bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    @MainActor static func herdrOpen(_ s: HerdrSpace, store: Store) {
        herdr(["space.select", "--id", s.id], store: store)
    }

    /// The tab starts in the space's own folder; Herdr's default is whatever terminal happens to be focused.
    @MainActor static func herdrNewTab(_ s: HerdrSpace, store: Store) {
        // Always sent, even when empty (a space made in the home folder reports no folder).
        herdr(["tab.new", "--space", s.id, "--folder", s.folder], store: store)
    }

    /// One click, no prompt: a space named after the Mac, in the remote home folder.
    @MainActor static func herdrNewWorkspace(_ m: RemoteMac, store: Store) {
        guard let machine = store.machine(for: m) else { NSSound.beep(); return }
        herdr(["space.new", "--name", m.name, "--machine", machine.name], store: store)
    }

    /// The script Terminal runs to attach the Herdr terminal app to a Mac.
    static func herdrTerminalScript(herdr: String, _ m: RemoteMac) -> String? {
        let host = m.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = m.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let target = user.isEmpty ? host : "\(user)@\(host)"
        return "#!/bin/sh\nexec \(Herdr.shellQuote(herdr)) --remote \(Herdr.shellQuote(target))\n"
    }

    /// Opens a terminal window running `herdr --remote` for this Mac, through a .command file
    /// (no Automation permission needed). One file per host, overwritten each time.
    static func herdrTerminal(_ m: RemoteMac) {
        guard let cli = Herdr.terminalCLI(), let script = herdrTerminalScript(herdr: cli, m) else { NSSound.beep(); return }
        let safe = String(m.host.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.prefix(80))
        let url = Store.supportDir.appendingPathComponent("herdr-\(safe).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
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

// MARK: - Popover

/// The menu-bar popover's window, so actions that leave Hop can close it.
enum Popover {
    static weak var window: NSWindow?

    /// Closes the popover. Its status item has no action to trigger (SwiftUI tracks the mouse itself),
    /// so the window is closed directly; actions that bring another app forward dismiss it anyway.
    @MainActor
    static func close() {
        if let window, window.isVisible { window.close() }
    }
}

private final class WindowProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { Popover.window = window }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Online is a filled dot, offline a hollow ring, still-checking a dashed ring: readable without color.
struct ReachMark: View {
    let online: Bool?

    var body: some View {
        Group {
            switch online {
            case .some(true):  Circle().fill(Color.green)
            case .some(false): Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            case .none:        Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityLabel(online == true ? "Online" : online == false ? "Offline" : "Checking")
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.top, 6).padding(.leading, 4)
    }
}

/// One glyph for the most urgent state, then the counts in words.
struct AgentSummary: View {
    let agents: [HerdrAgent]

    var body: some View {
        if let lead = Herdr.leading(agents) {
            HStack(spacing: 4) {
                Image(systemName: lead.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(lead.color)
                    .accessibilityHidden(true)
                Text(Herdr.summary(agents))
                    .fontWeight(lead == .blocked ? .semibold : .regular)
                    .foregroundStyle(lead == .blocked ? Color.primary : Color.secondary)
            }
            .font(.caption)
        }
    }
}

struct WorkspaceRow: View {
    let space: HerdrSpace
    var showFolder = false
    var showSummary = true
    @EnvironmentObject var store: Store

    private var folderText: String {
        var parts = space.folder.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Users" || parts[0] == "home" {
            parts.removeFirst(2)
            return parts.isEmpty ? "~" : "~/" + parts.joined(separator: "/")
        }
        return space.folder
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(space.name).lineLimit(1)
                if showFolder {
                    Text("\(folderText) · \(space.tabCount) \(space.tabCount == 1 ? "tab" : "tabs")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if showSummary && store.showAgentStatus { AgentSummary(agents: space.agents) }
            }
            Spacer(minLength: 4)
            Button("Open") { Popover.close(); Actions.herdrOpen(space, store: store) }
                .accessibilityLabel("Open \(space.name) in Herdr")
            Button("New Tab") { Popover.close(); Actions.herdrNewTab(space, store: store) }
                .accessibilityLabel("New tab in \(space.name)")
        }
        .controlSize(.small)
    }
}

private struct AgentLine: View {
    let agent: HerdrAgent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: agent.state.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(agent.state.color)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text("Tab \(agent.tab) · \(agent.app)")
            Spacer()
            Text(agent.state.label)
                .fontWeight(agent.state == .blocked ? .semibold : .regular)
                .foregroundStyle(agent.state == .blocked ? Color.primary : Color.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// A matched Mac's Herdr workspaces and the actions on them.
struct HerdrBlock: View {
    let m: RemoteMac
    var detailed = false
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Herdr workspaces").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(store.spaces(for: m)) { s in
                VStack(alignment: .leading, spacing: 4) {
                    WorkspaceRow(space: s, showFolder: detailed, showSummary: !detailed)
                    if detailed && store.showAgentStatus {
                        ForEach(Array(s.agents.enumerated()), id: \.offset) { _, a in AgentLine(agent: a) }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    Popover.close(); Actions.herdrNewWorkspace(m, store: store)
                } label: {
                    Label("New Workspace", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if !detailed && store.herdrTerminalInstalled {
                    Button { Popover.close(); Actions.herdrTerminal(m) } label: {
                        Text("Herdr in Terminal").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Open Herdr in Terminal on \(m.name)")
                }
            }
            if detailed {
                Text("Creates a space named “\(m.name)” in the remote home folder. No prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MacRow: View {
    let m: RemoteMac
    let open: () -> Void
    @EnvironmentObject var store: Store

    private var subtitle: String {
        if store.online[m.id] == false { return "Offline" }
        return m.user.isEmpty ? m.host : "\(m.user)@\(m.host)"
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 10) {
                    ReachMark(online: store.online[m.id])
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).fontWeight(.semibold).lineLimit(1)
                        Text(subtitle.isEmpty ? "No host set" : subtitle)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    let blocked = store.blocked(for: m)
                    if blocked > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: AgentState.blocked.symbol)
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text("\(blocked) blocked").font(.caption).fontWeight(.semibold)
                        }
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all actions for \(m.name)")
            IconButton(symbol: "display", label: "Screen Share \(m.name)") { Popover.close(); Actions.screenShare(m) }
            IconButton(symbol: "terminal", label: "SSH to \(m.name)") { Popover.close(); Actions.ssh(m) }
            IconButton(symbol: "folder", label: "Open shared files on \(m.name)") { Popover.close(); Actions.files(m) }
            if m.isTailnet {
                IconButton(symbol: "plus.circle", label: "Add \(m.name) to My Macs") { store.pin(m) }
            }
        }
    }
}

private struct ActionTile: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

struct MacDetailView: View {
    let m: RemoteMac
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ActionTile(symbol: "display", title: "Screen Share") { Popover.close(); Actions.screenShare(m) }
                ActionTile(symbol: "terminal", title: "SSH") { Popover.close(); Actions.ssh(m) }
                ActionTile(symbol: "folder", title: "Files") { Popover.close(); Actions.files(m) }
                ActionTile(symbol: "doc.on.doc", title: "Copy Address") { Actions.copyAddress(m) }
                if !m.mac.isEmpty {
                    ActionTile(symbol: "power", title: "Wake") { Actions.wake(m) }
                }
            }
            if store.machine(for: m) != nil {
                HerdrBlock(m: m, detailed: true)
            }
            if store.herdrTerminalInstalled && !m.host.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { Popover.close(); Actions.herdrTerminal(m) } label: {
                    Label("Open Herdr in Terminal", systemImage: "terminal").frame(maxWidth: .infinity)
                }
            }
            if m.isTailnet {
                Button { store.pin(m) } label: { Text("Add to My Macs").frame(maxWidth: .infinity) }
            }
            Text(m.user.isEmpty ? m.host : "\(m.user)@\(m.host)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// The four agent status choices, shared by the popover and the Manage window.
struct AgentStatusMenu: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let mode = store.agentMode.resolved(at: Date())
        Menu {
            Button { store.agentMode = .on } label: { choice("On", mode == .on) }
            Button("Mute for 8 Hours") { store.mute(for: AgentStatusMode.eightHours) }
            Button("Mute for 1 Week") { store.mute(for: AgentStatusMode.oneWeek) }
            Button { store.agentMode = .off } label: { choice("Off", mode == .off) }
        } label: {
            Text("Agent status: \(mode.shortLabel)")
        }
        .accessibilityLabel("Agent status, \(mode.label)")
    }

    @ViewBuilder
    private func choice(_ title: String, _ selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var detail: UUID?
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        let selected = store.mac(detail)
        VStack(spacing: 0) {
            if let m = selected { detailHeader(m) } else { header }
            ScrollView {
                Group {
                    if let m = selected { MacDetailView(m: m) } else { list }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 60), 520))
            Divider()
            footer
        }
        .frame(width: 400)
        .background(WindowAccessor())
        .onAppear { store.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Hop").font(.headline)
            Spacer()
            Text("\(store.onlineCount) of \(store.totalCount) online")
                .font(.caption).foregroundStyle(.secondary)
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh() }
                .keyboardShortcut("r")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
    }

    private func detailHeader(_ m: RemoteMac) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", label: "Back to all Macs") { detail = nil }
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    ReachMark(online: store.online[m.id])
                    Text(statusLine(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh() }
                .keyboardShortcut("r")
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 6)
    }

    private func statusLine(_ m: RemoteMac) -> String {
        var parts = [store.online[m.id] == true ? "Online" : store.online[m.id] == false ? "Offline" : "Checking"]
        if m.isTailnet { parts.append("Tailscale") }
        if let machine = store.machine(for: m) {
            parts.append(machine.state.isEmpty ? "Herdr" : "Herdr \(machine.state)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            banners
            SectionLabel("My Macs")
            if store.hosts.isEmpty {
                Text("No saved Macs yet").foregroundStyle(.secondary).padding(.leading, 4).padding(.vertical, 4)
            }
            ForEach(store.hosts) { m in macBlock(m) }
            if store.showTailscale {
                SectionLabel("Tailscale")
                switch store.tailscaleState {
                case .running:
                    if store.tailnet.isEmpty {
                        Text(store.tailscaleMacsOnly ? "No other Macs on your tailnet" : "No other devices on your tailnet")
                            .foregroundStyle(.secondary).padding(.leading, 4).padding(.vertical, 4)
                    }
                    ForEach(store.tailnet) { m in macBlock(m) }
                case .notInstalled:
                    Button("Install Tailscale…") { Popover.close(); Actions.openTailscale() }.padding(.leading, 4)
                case .notRunning(let msg):
                    Button("\(msg) — Open Tailscale") { Popover.close(); Actions.openTailscale() }.padding(.leading, 4)
                case .unknown:
                    Text("Checking Tailscale…").foregroundStyle(.secondary).padding(.leading, 4).padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func macBlock(_ m: RemoteMac) -> some View {
        if store.machine(for: m) != nil {
            VStack(alignment: .leading, spacing: 8) {
                MacRow(m: m) { detail = m.id }
                Divider()
                HerdrBlock(m: m)
            }
            .padding(.leading, 8).padding(.trailing, 6).padding(.top, 2).padding(.bottom, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        } else {
            MacRow(m: m) { detail = m.id }.padding(.leading, 8).padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private var banners: some View {
        let b = store.banners
        ForEach(b.shown) { banner in
            let waiting = banner.space.agents.filter { $0.state == .blocked }
            HStack(spacing: 10) {
                Image(systemName: AgentState.blocked.symbol).foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(waiting.count == 1 ? "\(waiting[0].app) is waiting for you" : "\(waiting.count) agents are waiting for you")
                        .fontWeight(.semibold).lineLimit(1)
                    Text("\(banner.space.name) on \(banner.macName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Open") { Popover.close(); Actions.herdrOpen(banner.space, store: store) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityLabel("Open \(banner.space.name) in Herdr")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.45)))
        }
        if b.more > 0 {
            Text("and \(b.more) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            let mode = store.agentMode.resolved(at: Date())
            if store.herdrAppInstalled && mode != .on {
                HStack {
                    Image(systemName: "bell.slash").accessibilityHidden(true)
                    Text(mode == .off ? "Agent status is off" : "Agent status m\(mode.label.dropFirst())")
                    Spacer()
                    Button("Turn On") { store.agentMode = .on }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 8)
            }
            HStack(spacing: 10) {
                Button("Manage Macs…") {
                    Popover.close()
                    openWindow(id: "manager")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")
                .fixedSize()
                if store.herdrAppInstalled {
                    AgentStatusMenu().menuStyle(.borderlessButton).fixedSize()
                }
                Menu("More") {
                    Button("Open Screen Sharing") { Popover.close(); Actions.openScreenSharingApp() }
                    Divider()
                    Button("Hop on GitHub") { Popover.close(); Actions.openGitHub() }
                    Button("Report an Issue…") { Popover.close(); Actions.reportIssue() }
                    Button("About Hop \(HopInfo.version)") { Popover.close(); Actions.showAbout() }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Quit Hop") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: - Manager window

struct ManagerView: View {
    @EnvironmentObject var store: Store
    @State private var selection: UUID?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private func row(_ m: RemoteMac) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ReachMark(online: store.online[m.id])
                Text(m.name)
            }
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
                    herdrSection(store.hosts[i])
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
                    herdrSection(m)
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
                if store.herdrAppInstalled { AgentStatusMenu() }
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

    /// Herdr machine, workspaces and actions for a Mac, under the same agent status rules as the popover.
    @ViewBuilder
    private func herdrSection(_ m: RemoteMac) -> some View {
        if let machine = store.machine(for: m) {
            Section {
                ForEach(store.spaces(for: m)) { s in
                    WorkspaceRow(space: s, showFolder: true)
                }
                HStack {
                    Button("New Workspace") { Actions.herdrNewWorkspace(m, store: store) }
                    if store.herdrTerminalInstalled {
                        Button("Open Herdr in Terminal") { Actions.herdrTerminal(m) }
                    }
                }
            } header: {
                Text("Herdr")
            } footer: {
                Text("Machine “\(machine.name)”\(machine.state.isEmpty ? "" : " · \(machine.state)"). New Workspace creates a space named after this Mac in its home folder, with no prompt.")
            }
        } else if store.herdrTerminalInstalled && !m.host.trimmingCharacters(in: .whitespaces).isEmpty {
            Section("Herdr") {
                Button("Open Herdr in Terminal") { Actions.herdrTerminal(m) }
            }
        }
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
            PopoverView().environmentObject(store)
        } label: {
            // The glyph, plus the number of agents waiting for you when agent status is on.
            HStack(spacing: 3) {
                Image(nsImage: HopGlyph.image)
                if store.totalBlocked > 0 { Text("\(store.totalBlocked)") }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Manage Macs", id: "manager") {
            ManagerView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}
