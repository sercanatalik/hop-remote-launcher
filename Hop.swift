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
import UserNotifications
import Carbon.HIToolbox
import Combine

// MARK: - Model

/// What kind of computer a host is. It decides the desktop action: Remote Desktop for Windows,
/// Screen Share for the others.
enum Platform: String, Codable, CaseIterable, Identifiable {
    case mac, windows, linux

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mac:     return "Mac"
        case .windows: return "Windows"
        case .linux:   return "Linux"
        }
    }

    /// From Tailscale's OS name. Phones, tablets and TVs are not computers Hop can reach, so they give nil.
    init?(tailscaleOS os: String) {
        switch os.lowercased() {
        case "macos":   self = .mac
        case "windows": self = .windows
        case "linux":   self = .linux
        default:        return nil
        }
    }

    /// The port its desktop action connects to: Remote Desktop or Screen Sharing.
    var desktopPort: UInt16 { self == .windows ? Probe.rdp : Probe.vnc }
    var desktopName: String { self == .windows ? "Remote Desktop" : "Screen Share" }
    var desktopSymbol: String { self == .windows ? "pc" : "display" }
}

struct RemoteMac: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "New Mac"
    var host: String = ""      // hostname, Bonjour name (studio.local), IP, or Tailscale name
    var user: String = ""      // optional account name on the remote Mac
    var mac: String = ""       // optional MAC address for Wake-on-LAN (aa:bb:cc:dd:ee:ff)
    var platform: Platform = .mac   // absent in host lists saved before platforms existed
    var sshAlias: String = ""  // its entry in ~/.ssh/config, when it was added from there
    var sshPort: Int = 0       // that entry's SSH port; 0 means the usual 22
    var isTailnet = false      // discovered from Tailscale (not saved)

    enum CodingKeys: String, CodingKey { case id, name, host, user, mac, platform, sshAlias, sshPort }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Mac"
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        user = (try? c.decode(String.self, forKey: .user)) ?? ""
        mac  = (try? c.decode(String.self, forKey: .mac)) ?? ""
        platform = (try? c.decode(Platform.self, forKey: .platform)) ?? .mac
        sshAlias = (try? c.decode(String.self, forKey: .sshAlias)) ?? ""
        sshPort  = (try? c.decode(Int.self, forKey: .sshPort)) ?? 0
    }
}

// MARK: - SSH configuration

/// One named host from the user's SSH configuration.
struct SSHHost: Identifiable, Hashable {
    let alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var id: String { alias }
}

/// Reads host names out of ~/.ssh/config. It only decides which names to offer; the connection itself
/// is made by `ssh` through the alias, so `ssh` stays the judge of what the file means.
enum SSHConfig {
    static var defaultPath: String { NSHomeDirectory() + "/.ssh/config" }

    /// The named hosts in the file and the files it includes, in file order. Names with wildcards are
    /// left out and `Match` blocks are skipped. Nil when there is no file.
    static func hosts(at path: String = defaultPath) -> [SSHHost]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var found: [SSHHost] = []
        var index: [String: Int] = [:]
        var earlier: [SSHHost] = []       // the defaults already set when each host was first named
        var defaults = SSHHost(alias: "*")
        var current: [String] = []        // aliases the lines being read apply to
        var inDefaults = true             // before the first Host line, or under "Host *"
        var skipping = false              // inside a Match block
        read(path, depth: 0, found: &found, index: &index, earlier: &earlier, defaults: &defaults,
             current: &current, inDefaults: &inDefaults, skipping: &skipping)
        // ssh keeps the first value it meets: a default set above a host's block wins over the block,
        // and a default set below it only fills what the block left out.
        return zip(found, earlier).map { h, pre in
            var h = h
            h.hostName = pre.hostName ?? h.hostName ?? defaults.hostName
            h.user = pre.user ?? h.user ?? defaults.user
            h.port = pre.port ?? h.port ?? defaults.port
            return h
        }
    }

    /// Splits a line's value into words, keeping a double-quoted run together.
    private static func words(_ value: String) -> [String] {
        var out: [String] = []
        var word = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle() }
            else if (ch == " " || ch == "\t") && !quoted { if !word.isEmpty { out.append(word); word = "" } }
            else { word.append(ch) }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    private static func read(_ path: String, depth: Int, found: inout [SSHHost], index: inout [String: Int],
                             earlier: inout [SSHHost], defaults: inout SSHHost, current: inout [String], inDefaults: inout Bool, skipping: inout Bool) {
        guard depth < 8, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Keyword value", "Keyword=value" or "Keyword = value"
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" || $0 == "=" }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let rest = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
            let value = words(rest).first ?? ""
            switch key {
            case "host":
                skipping = false
                let names = words(rest)
                inDefaults = names == ["*"]
                current = names.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                for name in current where index[name] == nil {
                    index[name] = found.count
                    found.append(SSHHost(alias: name))
                    earlier.append(defaults)
                }
            case "match":
                skipping = true
                inDefaults = false
                current = []
            case "include":
                for pattern in words(rest) {
                    for file in expand(pattern) {
                        read(file, depth: depth + 1, found: &found, index: &index, earlier: &earlier, defaults: &defaults,
                             current: &current, inDefaults: &inDefaults, skipping: &skipping)
                    }
                }
            case "hostname", "user", "port":
                guard !skipping else { continue }
                func set(_ h: inout SSHHost) {      // ssh keeps the first value it meets
                    switch key {
                    case "hostname": if h.hostName == nil { h.hostName = value }
                    case "user":     if h.user == nil { h.user = value }
                    default:         if h.port == nil { h.port = Int(value) }
                    }
                }
                if inDefaults { set(&defaults) }
                for name in current { if let i = index[name] { set(&found[i]) } }
            default:
                continue
            }
        }
    }

    /// An Include path: relative to ~/.ssh, with ~ and * expanded.
    private static func expand(_ pattern: String) -> [String] {
        var p = pattern
        if p.hasPrefix("~") { p = NSHomeDirectory() + p.dropFirst() }
        else if !p.hasPrefix("/") { p = NSHomeDirectory() + "/.ssh/" + p }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(p, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
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
            // The Tailscale app's binary is both the GUI and the command-line tool, and picks its mode
            // from the environment. An app started from Finder or at login has a bare environment, in
            // which the binary tries to be the GUI and prints "The Tailscale GUI failed to start" in
            // place of the status. TAILSCALE_BE_CLI is Tailscale's switch for forcing the tool.
            var env = ProcessInfo.processInfo.environment
            env["TAILSCALE_BE_CLI"] = "1"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (.notRunning("Couldn't run Tailscale"), []) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return interpret(data)
        }.value
    }

    /// Turns the output of `tailscale status --json` into a state and the peers. No output means the
    /// Tailscale service did not answer; output that is not a status is reported as unreadable.
    static func interpret(_ data: Data) -> (TailscaleState, [TailscalePeer]) {
        do {
            guard let s = try? JSONDecoder().decode(Status.self, from: data) else {
                let blank = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
                return (.notRunning(blank ? "Tailscale isn't running" : "Couldn't read Tailscale's status"), [])
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
        }
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

// MARK: - Reachability alerts

/// Decides when a saved Mac going offline or coming back is worth a notification.
/// A Mac is reported offline after two misses at least `minGap` apart, and reported back only if
/// Hop reported it offline. A quiet check updates what Hop believes without reporting anything.
struct ReachTracker {
    enum Event: Equatable { case offline, back }
    static let minGap: TimeInterval = 20

    private struct Entry {
        var online: Bool
        var misses = 0
        var firstMiss: Date?
        var announced = false
    }
    private var entries: [UUID: Entry] = [:]

    mutating func observe(_ id: UUID, online: Bool, quiet: Bool, now: Date = Date()) -> Event? {
        guard var e = entries[id] else {
            entries[id] = Entry(online: online)     // first sighting, whatever its state, is never news
            return nil
        }
        defer { entries[id] = e }
        if online {
            e.misses = 0
            e.firstMiss = nil
            guard !e.online else { return nil }
            e.online = true
            let wasAnnounced = e.announced
            e.announced = false
            return wasAnnounced && !quiet ? .back : nil
        }
        e.misses += 1
        if e.firstMiss == nil { e.firstMiss = now }
        guard e.online, e.misses >= 2, now.timeIntervalSince(e.firstMiss ?? now) >= ReachTracker.minGap else { return nil }
        e.online = false
        guard !quiet else { return nil }
        e.announced = true
        return .offline
    }
}

private final class AlertPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

enum Alerts {
    private static let presenter = AlertPresenter()

    /// Notifications need a bundle; a bare binary has none.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let c = UNUserNotificationCenter.current()
        c.delegate = presenter
        return c
    }

    static func request() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    static func denied() async -> Bool {
        guard let center else { return true }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    static func post(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Quick open

/// The global shortcut that opens the popover, and the way to open the popover from code.
///
/// Tried on macOS 27.2: a SwiftUI MenuBarExtra cannot be opened
/// from code. Its button (an NSStatusBarButton with no action or target, on an NSSceneStatusItem) ignored
/// performClick, a synthetic mouse-down and mouse-up sent to its window, and a direct mouseDown. Hop
/// therefore owns its status item and popover (see AppController), which the shortcut toggles.
/// RegisterEventHotKey worked for all three presets.
enum QuickOpen {
    struct Choice: Identifiable {
        let id: String
        let label: String
        let key: Int
        let modifiers: Int
    }

    static let off = "off"
    static let choices: [Choice] = [
        Choice(id: "ctrl-opt-space", label: "⌃⌥Space", key: kVK_Space, modifiers: controlKey | optionKey),
        Choice(id: "ctrl-opt-h", label: "⌃⌥H", key: kVK_ANSI_H, modifiers: controlKey | optionKey),
        Choice(id: "opt-cmd-h", label: "⌥⌘H", key: kVK_ANSI_H, modifiers: optionKey | cmdKey),
    ]

    static func label(_ id: String) -> String { choices.first { $0.id == id }?.label ?? "Off" }

    private static var hotKey: EventHotKeyRef?
    private static var handlerInstalled = false

    /// Registers the shortcut, replacing any earlier one. "off" unregisters. False means the shortcut
    /// is held by another app; nothing is registered then.
    static func register(_ id: String) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let choice = choices.first(where: { $0.id == id }) else { return true }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in QuickOpen.togglePopover() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x484F5021), id: 1)   // "HOP!"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(choice.key), UInt32(choice.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        return true
    }

    /// Opens the popover, or closes it when it is open.
    @MainActor
    static func togglePopover() { AppController.shared?.togglePopover() }
}

/// What the user has typed into the Mac list, and which listed Mac is highlighted.
@MainActor
final class KeyNav: ObservableObject {
    @Published var query = ""
    @Published var index = 0
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?

    /// Key presses in the popover go to `handle` first; it returns true for the ones it used.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window != nil, event.window === Popover.window else { return event }
            return self.handle?(event) == true ? nil : event
        }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var hosts: [RemoteMac] = [] { didSet { save() } }
    @Published var online: [UUID: Bool] = [:]
    /// Hosts named in ~/.ssh/config that are not saved yet; nil when there is no such file.
    @Published var sshConfigHosts: [SSHHost]?
    /// The service ports each host accepted at its last check. No entry means not checked yet.
    @Published var services: [UUID: Set<UInt16>] = [:]

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

    // Reachability alerts
    /// Milliseconds the last successful check took to reach each Mac.
    @Published var latency: [UUID: Int] = [:]
    @Published private(set) var alertsEnabled = UserDefaults.standard.bool(forKey: "reachabilityAlerts") {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "reachabilityAlerts") }
    }
    /// Notifications are refused for Hop in System Settings.
    @Published var alertsDenied = false
    @Published var alertsDeniedPrompt = false
    private var reach = ReachTracker()

    // Quick open
    @Published private(set) var hotkey = UserDefaults.standard.string(forKey: "quickOpenHotkey") ?? QuickOpen.off {
        didSet { UserDefaults.standard.set(hotkey, forKey: "quickOpenHotkey") }
    }
    /// Counts each time the popover is shown, so the list can start clean.
    @Published var popoverShows = 0
    /// Why the chosen shortcut could not be set, when it could not.
    @Published var hotkeyProblem: String?
    @Published var hotkeyProblemPrompt = false
    private let pathMonitor = NWPathMonitor()
    private var hasNetwork = true
    /// The next check only records state: set at launch, after wake and when the network comes back.
    private var quietNextCheck = true

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
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if up && !self.hasNetwork { self.quietNextCheck = true }
                self.hasNetwork = up
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.quietNextCheck = true }
        }
        if alertsEnabled {
            Task { if await Alerts.denied() { self.alertsEnabled = false; self.alertsDenied = true } }
        }
        if hotkey != QuickOpen.off {
            let saved = hotkey
            DispatchQueue.main.async { [weak self] in self?.setHotkey(saved, prompt: false) }
        }
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
        let quiet = quietNextCheck
        quietNextCheck = false
        for m in hosts where !m.host.trimmingCharacters(in: .whitespaces).isEmpty {
            let id = m.id, name = m.name, host = m.host.trimmingCharacters(in: .whitespaces), sshPort = m.sshPort
            Task {
                let open = await Probe.services(host: host, sshPort: sshPort)
                let up = !open.isEmpty      // online when any service answers
                self.online[id] = up
                self.services[id] = Set(open.keys)
                self.latency[id] = open.values.min()
                self.noteReach(id, name: name, online: up, quiet: quiet)
            }
        }
        refreshTailscale()
        refreshHerdr()
    }

    // MARK: Reachability alerts

    /// Feeds one check of a saved Mac to the tracker and posts a notification when it is news.
    /// Nothing is counted while this computer has no network, so a local outage reports no Mac.
    private func noteReach(_ id: UUID, name: String, online: Bool, quiet: Bool) {
        guard hasNetwork, hosts.contains(where: { $0.id == id }) else { return }
        guard let event = reach.observe(id, online: online, quiet: quiet), alertsEnabled else { return }
        switch event {
        case .offline: Alerts.post(title: "\(name) is offline", body: "No answer for about a minute.")
        case .back:    Alerts.post(title: "\(name) is back online", body: "Hop can reach it again.")
        }
    }

    /// Turning alerts on asks for notification permission; a refusal leaves them off and says why.
    func setAlerts(_ on: Bool) {
        guard on else { alertsEnabled = false; return }
        Task {
            if await Alerts.request() {
                alertsEnabled = true
                alertsDenied = false
            } else {
                alertsEnabled = false
                alertsDenied = true
                alertsDeniedPrompt = true
            }
        }
    }

    // MARK: SSH configuration

    /// Reads ~/.ssh/config and keeps the hosts that are not in My Macs yet. Called when the Manage Macs
    /// window opens and on its Refresh, not on the timer.
    func refreshSSHConfig() {
        guard let all = SSHConfig.hosts() else { sshConfigHosts = nil; return }
        let aliases = Set(hosts.map { $0.sshAlias.lowercased() })
        let addresses = Set(hosts.map { $0.host.lowercased().trimmingCharacters(in: .whitespaces) })
        sshConfigHosts = all.filter {
            !aliases.contains($0.alias.lowercased()) && !addresses.contains($0.alias.lowercased())
        }
    }

    /// Saves a host from the SSH configuration to My Macs, remembering its entry so SSH can use it.
    func add(_ h: SSHHost) -> UUID {
        var m = RemoteMac()
        m.name = h.alias
        m.host = h.hostName ?? h.alias
        m.user = h.user ?? ""
        m.sshAlias = h.alias
        m.sshPort = h.port ?? 0
        hosts.append(m)
        refreshSSHConfig()
        refresh()
        return m.id
    }

    // MARK: Quick open

    /// Sets the global shortcut. One held by another app leaves the shortcut off and says so.
    func setHotkey(_ id: String, prompt: Bool = true) {
        if QuickOpen.register(id) {
            hotkey = id
            hotkeyProblem = nil
        } else {
            _ = QuickOpen.register(QuickOpen.off)
            hotkey = QuickOpen.off
            hotkeyProblem = "\(QuickOpen.label(id)) is already used by another app, so no shortcut is set."
            hotkeyProblemPrompt = prompt
        }
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

    /// False only when the host is online and refused a connection on that port at the last check.
    func accepts(_ m: RemoteMac, _ port: UInt16) -> Bool {
        guard online[m.id] == true, let open = services[m.id] else { return true }
        return open.contains(port)
    }

    func filesAvailable(_ m: RemoteMac) -> Bool { accepts(m, Probe.smb) }
    func sshAvailable(_ m: RemoteMac) -> Bool { accepts(m, Probe.ssh) }

    /// Why the desktop action (Screen Share or Remote Desktop) is dimmed, or nil when it is not.
    func desktopProblem(_ m: RemoteMac) -> String? {
        if m.platform == .windows && !Actions.canRemoteDesktop {
            return "Remote Desktop needs an app on this Mac. Choose it to get Windows App"
        }
        guard !accepts(m, m.platform.desktopPort) else { return nil }
        return m.platform == .windows ? "Remote Desktop appears to be off" : "Screen Sharing appears to be off"
    }

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
                guard let platform = Platform(tailscaleOS: p.os) else { continue }   // not a computer
                if tailscaleMacsOnly && platform != .mac { continue }
                let full = p.host.lowercased()
                let short = full.split(separator: ".").first.map(String.init) ?? full
                if saved.contains(full) || saved.contains(short) || p.ips.contains(where: { saved.contains($0) }) { continue }
                var m = RemoteMac()
                m.id = oldIDs[p.host] ?? UUID()
                m.name = p.name
                m.host = p.host
                m.platform = platform
                m.isTailnet = true
                list.append(m)
                online[m.id] = p.online
            }
            tailscaleState = state
            tailnet = list
            for m in list where online[m.id] == true {
                let id = m.id, host = m.host
                Task {
                    let open = await Probe.services(host: host)
                    self.services[id] = Set(open.keys)
                    if let ms = open.values.min() { self.latency[id] = ms }
                }
            }
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
        services[c.id] = services[m.id]
        tailnet.removeAll { $0.id == m.id }
        return c.id
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        online[id] = nil
        refreshTailscale()
        if sshConfigHosts != nil { refreshSSHConfig() }
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
    static let ssh: UInt16 = 22
    static let smb: UInt16 = 445
    static let rdp: UInt16 = 3389
    static let vnc: UInt16 = 5900
    static let all: [UInt16] = [vnc, ssh, smb, rdp]

    /// Checks every service port at once; the result maps each port that answered to its time in ms.
    static func services(host: String, sshPort: Int = 0) async -> [UInt16: Int] {
        let sshOn = (1...65535).contains(sshPort) ? UInt16(sshPort) : ssh   // a config entry's own port
        return await withTaskGroup(of: (UInt16, Int?).self) { group in
            for port in all { group.addTask { (port, await timed(host: host, port: port == ssh ? sshOn : port)) } }
            var open: [UInt16: Int] = [:]
            for await (port, ms) in group { if let ms { open[port] = ms } }
            return open
        }
    }

    static func tcp(host: String, port: UInt16, timeout: Double = 2.5) async -> Bool {
        await timed(host: host, port: port, timeout: timeout) != nil
    }

    /// How long the TCP connect took, in milliseconds, or nil when it did not connect.
    static func timed(host: String, port: UInt16, timeout: Double = 2.5) async -> Int? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let started = Date()
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: ok ? max(1, Int((Date().timeIntervalSince(started) * 1000).rounded())) : nil)
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

    // Remote Desktop hand-off. Checked on macOS 27.2 with no client installed: Launch Services returns
    // no app for rdp://, which is how Hop knows to dim the control. NOT checked: whether Windows App
    // starts a session from this URL (no Windows App and no Windows PC were available). Microsoft
    // documents the scheme for its Mac client; if Windows App ignores it, the fallback in the
    // plan is to write a .rdp file ("full address:s:<host>") and open that.
    private static let windowsAppPage = URL(string: "macappstore://apps.apple.com/app/id1295203466")!

    /// Whether any app on this Mac opens Remote Desktop connections.
    static var canRemoteDesktop: Bool {
        guard let probe = URL(string: "rdp://full%20address=s%3Alocalhost") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    static func remoteDesktopURL(_ m: RemoteMac) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let host = m.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let h = host.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var s = "rdp://full%20address=s%3A\(h)%3A\(Probe.rdp)"
        let user = m.user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty, let u = user.addingPercentEncoding(withAllowedCharacters: allowed) { s += "&username=s%3A\(u)" }
        return URL(string: s)
    }

    /// Opens a Remote Desktop connection in the installed client, or the page to get one.
    static func remoteDesktop(_ m: RemoteMac) {
        guard canRemoteDesktop else { NSWorkspace.shared.open(windowsAppPage); return }
        guard let u = remoteDesktopURL(m) else { NSSound.beep(); return }
        NSWorkspace.shared.open(u)
    }

    /// The host's desktop action: Remote Desktop for Windows, Screen Share otherwise.
    static func desktop(_ m: RemoteMac) {
        if m.platform == .windows { remoteDesktop(m) } else { screenShare(m) }
    }
    /// SSH. A Mac added from ~/.ssh/config connects through its entry there, so the port, key and jump
    /// host in the file apply; if the entry is gone, or for any other Mac, it connects to the address.
    static func ssh(_ m: RemoteMac) {
        guard let u = sshURL(m, configured: SSHConfig.hosts() ?? []) else { NSSound.beep(); return }
        NSWorkspace.shared.open(u)
    }

    static func sshURL(_ m: RemoteMac, configured: [SSHHost]) -> URL? {
        var c = URLComponents()
        c.scheme = "ssh"
        if !m.sshAlias.isEmpty, configured.contains(where: { $0.alias == m.sshAlias }) {
            c.host = m.sshAlias          // ssh fills in user, port and the rest from the entry
            return c.url
        }
        let host = m.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        c.host = host
        let user = m.user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { c.user = user }
        if (1...65535).contains(m.sshPort), m.sshPort != 22 { c.port = m.sshPort }
        return c.url
    }
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

/// The menu-bar popover: its window, for telling its key presses apart, and the way to close it.
enum Popover {
    static weak var window: NSWindow?

    /// Closes the popover after an action that leaves Hop.
    @MainActor
    static func close() { AppController.shared?.closePopover() }
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
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: size, height: size)
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
            .padding(.top, 6).padding(.leading, 8)
    }
}

/// A quiet highlight behind the row the pointer is over.
private struct HoverFill: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(on ? 0.07 : 0))
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

/// A workspace with its actions. `compact` (the popover's detail view) turns New Tab into a "+" button.
struct WorkspaceRow: View {
    let space: HerdrSpace
    var showFolder = false
    var showSummary = true
    var compact = false
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
        HStack(spacing: compact ? 4 : 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(space.name).lineLimit(1)
                if showFolder {
                    Text("\(folderText) · \(space.tabCount) \(space.tabCount == 1 ? "tab" : "tabs")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if showSummary && store.showAgentStatus { AgentSummary(agents: space.agents) }
            }
            Spacer(minLength: 4)
            if compact {
                IconButton(symbol: "plus", label: "New tab in \(space.name)", size: 24) {
                    Popover.close(); Actions.herdrNewTab(space, store: store)
                }
            }
            Button("Open") { Popover.close(); Actions.herdrOpen(space, store: store) }
                .accessibilityLabel("Open \(space.name) in Herdr")
            if !compact {
                Button("New Tab") { Popover.close(); Actions.herdrNewTab(space, store: store) }
                    .accessibilityLabel("New tab in \(space.name)")
            }
        }
        .controlSize(.small)
    }
}

/// A workspace under a Mac's row in the list: the row opens it, "+" adds a tab.
struct SpaceLine: View {
    let space: HerdrSpace
    @EnvironmentObject var store: Store
    @State private var hovering = false

    var body: some View {
        let showStatus = store.showAgentStatus && !space.agents.isEmpty
        HStack(spacing: 2) {
            Button { Popover.close(); Actions.herdrOpen(space, store: store) } label: {
                HStack(spacing: 6) {
                    Text(space.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if showStatus { AgentSummary(agents: space.agents) }
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(space.name) in Herdr")
            .accessibilityLabel("Open \(space.name) in Herdr")
            .accessibilityValue(showStatus ? Herdr.summary(space.agents) : "")
            IconButton(symbol: "plus", label: "New tab in \(space.name)", size: 24) {
                Popover.close(); Actions.herdrNewTab(space, store: store)
            }
        }
        .padding(.leading, 27).padding(.trailing, 4)
        .background(HoverFill(on: hovering))
        .onHover { hovering = $0 }
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

/// A matched Mac's Herdr workspaces in its detail view, with one line per agent.
struct HerdrBlock: View {
    let m: RemoteMac
    @EnvironmentObject var store: Store

    var body: some View {
        let spaces = store.spaces(for: m)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Workspaces").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Popover.close(); Actions.herdrNewWorkspace(m, store: store)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help("Creates a workspace named “\(m.name)” in the remote home folder, with no prompt")
                .accessibilityLabel("New workspace on \(m.name)")
            }
            ForEach(Array(spaces.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    WorkspaceRow(space: s, showFolder: true, showSummary: false, compact: true)
                    if store.showAgentStatus {
                        ForEach(Array(s.agents.enumerated()), id: \.offset) { _, a in AgentLine(agent: a) }
                    }
                }
            }
        }
    }
}

/// One line per Mac. Screen Share, SSH and Files appear while the pointer is over the row or one of them
/// has keyboard focus; VoiceOver gets them as actions on the row either way.
struct MacRow: View {
    let m: RemoteMac
    /// Chosen from the keyboard: shows the actions and an outline, so it does not rely on color.
    var highlighted = false
    let open: () -> Void
    @EnvironmentObject var store: Store
    @State private var hovering = false
    @FocusState private var focus: Int?

    private var note: String? {
        if store.online[m.id] == false { return "Offline" }
        if m.host.trimmingCharacters(in: .whitespaces).isEmpty { return "No host set" }
        let n = store.spaces(for: m).count
        if n > 0 { return "\(n) \(n == 1 ? "workspace" : "workspaces")" }
        return m.platform == .mac ? nil : m.platform.label
    }

    var body: some View {
        let reveal = hovering || focus != nil || highlighted
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 10) {
                    ReachMark(online: store.online[m.id])
                    Text(m.name).fontWeight(.semibold).lineLimit(1)
                        .foregroundStyle(store.online[m.id] == false ? Color.secondary : Color.primary)
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(note ?? "")
            .accessibilityHint("Shows all actions for \(m.name)")
            .accessibilityAction(named: Text(m.platform.desktopName)) { Popover.close(); Actions.desktop(m) }
            .accessibilityAction(named: "SSH") { Popover.close(); Actions.ssh(m) }
            .accessibilityAction(named: "Files") { Popover.close(); Actions.files(m) }
            ZStack(alignment: .trailing) {
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .opacity(reveal ? 0 : 1)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 0) {
                    let desktop = store.desktopProblem(m)
                    IconButton(symbol: m.platform.desktopSymbol,
                               label: "\(m.platform.desktopName) \(m.name)" + (desktop.map { ". \($0)" } ?? "")) {
                        Popover.close(); Actions.desktop(m)
                    }
                    .opacity(desktop == nil ? 1 : 0.35)
                    .focused($focus, equals: 1)
                    let ssh = store.sshAvailable(m)
                    IconButton(symbol: "terminal", label: ssh ? "SSH to \(m.name)" : "SSH to \(m.name). SSH appears to be off") {
                        Popover.close(); Actions.ssh(m)
                    }
                    .opacity(ssh ? 1 : 0.35)
                    .focused($focus, equals: 2)
                    let files = store.filesAvailable(m)
                    IconButton(symbol: "folder",
                               label: files ? "Open shared files on \(m.name)" : "Open shared files on \(m.name). File Sharing appears to be off") {
                        Popover.close(); Actions.files(m)
                    }
                    .opacity(files ? 1 : 0.35)
                    .focused($focus, equals: 3)
                }
                .opacity(reveal ? 1 : 0)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                .padding(.leading, 2)
                .accessibilityHidden(true)
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .background(HoverFill(on: hovering || highlighted))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: highlighted ? 1.5 : 0))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

struct MacDetailView: View {
    let m: RemoteMac
    /// Called with the saved Mac's id after "Add to My Macs", so the detail view can follow it.
    let pinned: (UUID) -> Void
    @EnvironmentObject var store: Store

    private var hasHost: Bool { !m.host.trimmingCharacters(in: .whitespaces).isEmpty }
    private var offersTerminal: Bool { store.herdrTerminalInstalled && hasHost }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                let desktop = store.desktopProblem(m)
                Button { Popover.close(); Actions.desktop(m) } label: {
                    Label(m.platform.desktopName, systemImage: m.platform.desktopSymbol)
                        .fixedSize().frame(maxWidth: .infinity)
                }
                .opacity(desktop == nil ? 1 : 0.45)
                .help(desktop ?? "\(m.platform.desktopName) \(m.name)")
                .accessibilityLabel(m.platform.desktopName + (desktop.map { ". \($0)" } ?? ""))
                let ssh = store.sshAvailable(m)
                Button { Popover.close(); Actions.ssh(m) } label: {
                    Label("SSH", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .opacity(ssh ? 1 : 0.45)
                .help(ssh ? "SSH to \(m.name)" : "SSH appears to be off on \(m.name)")
                .accessibilityLabel(ssh ? "SSH" : "SSH. SSH appears to be off")
                let files = store.filesAvailable(m)
                Button { Popover.close(); Actions.files(m) } label: {
                    Label("Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .opacity(files ? 1 : 0.45)
                .help(files ? "Open shared files on \(m.name)" : "File Sharing appears to be off on \(m.name)")
                .accessibilityLabel(files ? "Files" : "Files. File Sharing appears to be off")
                if !m.mac.isEmpty || offersTerminal || m.isTailnet {
                    Menu {
                        if !m.mac.isEmpty {
                            Button("Wake") { Actions.wake(m) }
                        }
                        if offersTerminal {
                            Button("Open Herdr in Terminal") { Popover.close(); Actions.herdrTerminal(m) }
                        }
                        if m.isTailnet {
                            Button("Add to My Macs") { pinned(store.pin(m)) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions for \(m.name)")
                }
            }
            .controlSize(.large)
            if store.machine(for: m) != nil {
                HerdrBlock(m: m)
            }
            VStack(spacing: 2) {
                Divider()
                HStack(spacing: 4) {
                    Text(m.user.isEmpty ? m.host : "\(m.user)@\(m.host)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    IconButton(symbol: "doc.on.doc", label: "Copy Address", size: 26) { Actions.copyAddress(m) }
                }
            }
        }
    }
}

/// The four agent status choices, shared by the popover and the Manage window.
struct AgentStatusMenu: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let mode = store.agentMode.resolved(at: Date())
        Menu {
            if case .muted = mode {
                Text(mode.label)
                Divider()
            }
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
    @StateObject private var nav = KeyNav()

    private var filtering: Bool { !nav.query.isEmpty }

    private func matches(_ m: RemoteMac) -> Bool {
        m.name.localizedCaseInsensitiveContains(nav.query) || m.host.localizedCaseInsensitiveContains(nav.query)
    }

    /// The Macs listed while text is typed, in the order they are drawn.
    private var matched: [RemoteMac] {
        store.hosts.filter(matches) + (store.showTailscale ? store.tailnet.filter(matches) : [])
    }

    private var highlighted: RemoteMac? {
        let list = matched
        return list.isEmpty ? nil : list[min(nav.index, list.count - 1)]
    }

    /// Keyboard in the Mac list: typing filters, arrows move the highlight, Return opens the highlighted
    /// Mac, Command-1 to 3 run its actions, Escape clears and then closes. Returns true for keys it used.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard store.mac(detail) == nil else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods == .command, filtering, let m = highlighted,
           let n = ["1", "2", "3"].firstIndex(of: event.charactersIgnoringModifiers ?? "") {
            Popover.close()
            switch n {
            case 0:  Actions.desktop(m)
            case 1:  Actions.ssh(m)
            default: Actions.files(m)
            }
            return true
        }
        guard mods.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if filtering { nav.query = ""; nav.index = 0 } else { Popover.close() }
            return true
        case kVK_Delete:
            guard filtering else { return false }
            nav.query.removeLast(); nav.index = 0
            return true
        case kVK_DownArrow:
            guard filtering else { return false }
            nav.index = min(nav.index + 1, max(matched.count - 1, 0))
            return true
        case kVK_UpArrow:
            guard filtering else { return false }
            nav.index = max(min(nav.index, matched.count - 1) - 1, 0)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard filtering, let m = highlighted else { return false }
            detail = m.id
            nav.query = ""; nav.index = 0
            return true
        default:
            guard let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }),
                  filtering || text != " " else { return false }
            nav.query += text
            nav.index = 0
            return true
        }
    }

    var body: some View {
        let selected = store.mac(detail)
        VStack(spacing: 0) {
            if let m = selected { detailHeader(m) } else if filtering { searchHeader } else { header }
            ScrollView {
                Group {
                    if let m = selected {
                        MacDetailView(m: m) { detail = $0 }.padding(.horizontal, 12)
                    } else if filtering {
                        filteredList.padding(.horizontal, 8)
                    } else {
                        list.padding(.horizontal, 8)
                    }
                }
                .padding(.bottom, 8)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 60), 520))
            if selected == nil { if filtering { keyLine } else { bottomLine } }
        }
        .frame(width: 400)
        .background(shortcuts)
        .background(WindowAccessor())
        .onAppear {
            nav.handle = { handleKey($0) }
            nav.install()
        }
        .onChange(of: store.popoverShows) { _ in nav.query = ""; nav.index = 0 }
    }

    /// Manage Macs and Quit, in plain view at the bottom of the Mac list, each with its shortcut.
    private var bottomLine: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button { openManager() } label: { keyHint("⌘,", "Manage Macs…", keyFirst: false) }
                    .accessibilityLabel("Manage Macs")
                Spacer()
                Button { NSApp.terminate(nil) } label: { keyHint("⌘Q", "Quit Hop", keyFirst: false) }
                    .accessibilityLabel("Quit Hop")
            }
            .buttonStyle(.plain)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
    }

    /// The typed text, in place of the title and the online count.
    private var searchHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(nav.query).fontWeight(.medium).lineLimit(1)
                .accessibilityLabel("Filtering by \(nav.query)")
            Spacer()
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh() }
                .keyboardShortcut("r")
            moreMenu
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
    }

    private func keyHint(_ key: String, _ what: String, keyFirst: Bool = true) -> some View {
        HStack(spacing: 5) {
            if !keyFirst { Text(what) }
            Text(key).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            if keyFirst { Text(what) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Names the keys that act on the list while text is typed.
    private var keyLine: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if highlighted != nil {
                    keyHint("↩", "Details")
                    keyHint("⌘1", highlighted?.platform.desktopName ?? "Screen Share")
                    keyHint("⌘2", "SSH")
                    keyHint("⌘3", "Files")
                }
                Spacer(minLength: 0)
                keyHint("esc", "Clear")
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private func openManager() {
        Popover.close()
        openWindow(id: "manager")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Command-comma and Command-Q, live in the list and in a detail view, whether or not the More menu
    /// is on screen.
    private var shortcuts: some View {
        Group {
            Button("Manage Macs") { openManager() }.keyboardShortcut(",")
            Button("Quit Hop") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Text("Hop").font(.headline)
            Text("\(store.onlineCount) of \(store.totalCount) online")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
            Spacer()
            let mode = store.agentMode.resolved(at: Date())
            if store.herdrAppInstalled && mode != .on {
                let text = mode == .off ? "Agent status is off" : "Agent status m\(mode.label.dropFirst())"
                Button { store.agentMode = .on } label: {
                    Image(systemName: "bell.slash").frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(text). Click to turn it on.")
                .accessibilityLabel("\(text). Turn on")
            }
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh() }
                .keyboardShortcut("r")
            moreMenu
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
    }

    private var moreMenu: some View {
        Menu {
            if store.herdrAppInstalled { AgentStatusMenu(); Divider() }
            Button("Open Screen Sharing") { Popover.close(); Actions.openScreenSharingApp() }
            Divider()
            Button("Hop on GitHub") { Popover.close(); Actions.openGitHub() }
            Button("Report an Issue…") { Popover.close(); Actions.reportIssue() }
            Button("About Hop \(HopInfo.version)") { Popover.close(); Actions.showAbout() }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
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
        if m.platform != .mac { parts.append(m.platform.label) }
        if let machine = store.machine(for: m) {
            parts.append(machine.state.isEmpty ? "Herdr" : "Herdr \(machine.state)")
        }
        if store.online[m.id] == true, let ms = store.latency[m.id] { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
    }

    // MARK: List

    /// The list while text is typed: only the Macs that match, without workspaces or banners.
    @ViewBuilder
    private var filteredList: some View {
        let mine = store.hosts.filter(matches)
        let tail = store.showTailscale ? store.tailnet.filter(matches) : []
        let chosen = highlighted?.id
        VStack(alignment: .leading, spacing: 2) {
            if mine.isEmpty && tail.isEmpty {
                Text("No Macs match “\(nav.query)”").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            if !mine.isEmpty {
                SectionLabel("My Macs")
                ForEach(mine) { m in MacRow(m: m, highlighted: m.id == chosen) { detail = m.id } }
            }
            if !tail.isEmpty {
                SectionLabel("Tailscale")
                ForEach(tail) { m in MacRow(m: m, highlighted: m.id == chosen) { detail = m.id } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            banners
            if !store.hosts.isEmpty {
                SectionLabel("My Macs")
                ForEach(store.hosts) { m in macBlock(m) }
            }
            if store.showTailscale {
                SectionLabel("Tailscale")
                switch store.tailscaleState {
                case .running:
                    if store.tailnet.isEmpty {
                        Text(store.tailscaleMacsOnly ? "No other Macs on your tailnet" : "No other devices on your tailnet")
                            .foregroundStyle(.secondary).padding(.leading, 8).padding(.vertical, 4)
                    }
                    ForEach(store.tailnet) { m in macBlock(m) }
                case .notInstalled:
                    Button("Install Tailscale…") { Popover.close(); Actions.openTailscale() }.padding(.leading, 8)
                case .notRunning(let msg):
                    Button("\(msg) — Open Tailscale") { Popover.close(); Actions.openTailscale() }.padding(.leading, 8)
                case .unknown:
                    Text("Checking Tailscale…").foregroundStyle(.secondary).padding(.leading, 8).padding(.vertical, 4)
                }
            } else if store.hosts.isEmpty {
                HStack {
                    Text("No Macs yet").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add a Mac…") { openManager() }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func macBlock(_ m: RemoteMac) -> some View {
        if store.machine(for: m) != nil {
            VStack(alignment: .leading, spacing: 0) {
                MacRow(m: m) { detail = m.id }
                ForEach(store.spaces(for: m)) { s in SpaceLine(space: s) }
                Button { Popover.close(); Actions.herdrNewWorkspace(m, store: store) } label: {
                    Label("New workspace", systemImage: "plus")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 27)
                .accessibilityLabel("New workspace on \(m.name)")
            }
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        } else {
            MacRow(m: m) { detail = m.id }
        }
    }

    @ViewBuilder
    private var banners: some View {
        let b = store.banners
        ForEach(b.shown) { banner in
            let waiting = banner.space.agents.filter { $0.state == .blocked }
            HStack(spacing: 8) {
                Image(systemName: AgentState.blocked.symbol)
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange).accessibilityHidden(true)
                Text(waiting.count == 1 ? "\(waiting[0].app) is waiting" : "\(waiting.count) agents are waiting")
                    .fontWeight(.semibold).lineLimit(1).layoutPriority(1)
                Text("\(banner.space.name) on \(banner.macName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Open") { Popover.close(); Actions.herdrOpen(banner.space, store: store) }
                    .controlSize(.small)
                    .accessibilityLabel("Open \(banner.space.name) in Herdr")
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.16)))
            .padding(.horizontal, 4).padding(.bottom, 2)
        }
        if b.more > 0 {
            Text("and \(b.more) more").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
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
                if let found = store.sshConfigHosts {
                    Section("From SSH config") {
                        ForEach(found) { h in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.alias)
                                    if let name = h.hostName, name != h.alias {
                                        Text(name).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button { selection = store.add(h) } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Add \(h.alias) to My Macs")
                                    .accessibilityLabel("Add \(h.alias) to My Macs")
                            }
                            .padding(.vertical, 2)
                        }
                        if found.isEmpty {
                            Text("Every host is already in My Macs").foregroundStyle(.secondary)
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
                    Button { store.refresh(); store.refreshSSHConfig() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh status, Tailscale devices and SSH config hosts")
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
                        Picker("Platform", selection: $store.hosts[i].platform) {
                            ForEach(Platform.allCases) { p in Text(p.label).tag(p) }
                        }
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
                Menu {
                    Picker("Open Hop from anywhere", selection: Binding(get: { store.hotkey }, set: { store.setHotkey($0) })) {
                        Text("Off").tag(QuickOpen.off)
                        ForEach(QuickOpen.choices) { c in Text(c.label).tag(c.id) }
                    }
                    .pickerStyle(.inline)
                    if let problem = store.hotkeyProblem {
                        Divider()
                        Text(problem)
                    }
                } label: {
                    Label("Shortcut", systemImage: "keyboard")
                }
                .accessibilityLabel("Shortcut to open Hop, \(QuickOpen.label(store.hotkey))")
            }
            ToolbarItem {
                Menu {
                    Toggle("Notify when a saved Mac goes offline or comes back",
                           isOn: Binding(get: { store.alertsEnabled }, set: { store.setAlerts($0) }))
                    Text("A Mac is reported after it misses two checks, about a minute.")
                    if store.alertsDenied {
                        Divider()
                        Text("Notifications are turned off for Hop in System Settings")
                        Button("Open System Settings…") { Alerts.openSettings() }
                    }
                } label: {
                    Label("Alerts", systemImage: store.alertsEnabled ? "bell.badge" : "bell")
                }
                .accessibilityLabel("Alerts, \(store.alertsEnabled ? "on" : "off")")
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
        .onAppear { store.refresh(); store.refreshSSHConfig() }
        .alert("Notifications are turned off for Hop", isPresented: $store.alertsDeniedPrompt) {
            Button("Open System Settings…") { Alerts.openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications for Hop in System Settings, then turn this on again to be told when a saved Mac goes offline or comes back.")
        }
        .alert("That shortcut is unavailable", isPresented: $store.hotkeyProblemPrompt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.hotkeyProblem ?? "")
        }
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
            Button(m.platform.desktopName) { Actions.desktop(m) }
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

/// Owns the menu-bar item and its popover. Hop does not use SwiftUI's MenuBarExtra because that cannot
/// be opened from code, which the global shortcut needs.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppController?

    let store = Store()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var watching: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared = self

        let host = NSHostingController(rootView: PopoverView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = HopGlyph.image
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.setAccessibilityLabel("Hop")
        self.item = item

        // The glyph, plus the number of agents waiting for you when agent status is on.
        watching = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
    }

    /// Hop lives in the menu bar: closing the popover or the Manage Macs window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateTitle() {
        let blocked = store.totalBlocked
        item?.button?.title = blocked > 0 ? " \(blocked)" : ""
    }

    @objc private func statusItemClicked() { togglePopover() }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = item?.button else { return }
        store.popoverShows += 1
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }
}

@main
struct HopApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var controller

    var body: some Scene {
        // Never shown. It stays the first scene so that the Manage Macs window below is a secondary
        // scene, which SwiftUI does not open at launch.
        MenuBarExtra("Hop", isInserted: .constant(false)) { EmptyView() }

        Window("Manage Macs", id: "manager") {
            ManagerView().environmentObject(controller.store)
        }
        .windowResizability(.contentSize)
    }
}
