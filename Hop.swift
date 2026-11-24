// Hop — a menu-bar launcher for connecting to remote Macs.
// Screen Sharing (vnc://), SSH in Terminal (ssh://), shared files (smb://),
// Wake-on-LAN, a live online/offline indicator, automatic discovery of
// the computers on your local network (Bonjour) and of
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
import SystemConfiguration
import dnssd
import os

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
    var origin: Origin = .saved   // where the row came from; a found one is not in My Macs yet (not saved)
    var links: [HostLink] = [] // named links shown in its detail view; absent in lists saved before links existed

    /// My Macs, or one of the two places Hop finds computers by itself.
    enum Origin { case saved, tailscale, nearby }

    enum CodingKeys: String, CodingKey { case id, name, host, user, mac, platform, sshAlias, sshPort, links }

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
        links    = (try? c.decode([HostLink].self, forKey: .links)) ?? []
    }

    /// Links are written only where there are some, so a list without them is what it always was.
    /// One with no name or no address is not kept.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(user, forKey: .user)
        try c.encode(mac, forKey: .mac)
        try c.encode(platform, forKey: .platform)
        try c.encode(sshAlias, forKey: .sshAlias)
        try c.encode(sshPort, forKey: .sshPort)
        let kept = links.filter(\.complete)
        if !kept.isEmpty { try c.encode(Array(kept.prefix(HostLink.limit)), forKey: .links) }
    }
}

// MARK: - Links

/// A named link kept with a saved computer: a web page it serves, another port, anything with an
/// address. `{host}` in the address stands for wherever Hop reaches the computer right now.
struct HostLink: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    var address = ""

    /// How many links one computer can carry.
    static let limit = 8
    static let placeholder = "{host}"

    init() {}

    init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id      = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name    = (try? c.decode(String.self, forKey: .name)) ?? ""
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
    }

    /// Whether the link points at the computer itself, so that opening it is connecting to it.
    var usesHost: Bool { address.contains(Self.placeholder) }

    /// Both a name and an address: anything less is not kept.
    var complete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether text starts with a scheme. "nas.local:5000" does not: what follows the colon there
    /// is a port number, so the colon belongs to an address typed without a scheme.
    static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), let first = text.first, first.isLetter, first.isASCII else { return false }
        let scheme = text[..<colon]
        guard scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return false }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return true }
        let digits = rest.prefix { $0.isNumber }
        // host:port, host:port/path
        if !digits.isEmpty, digits.endIndex == rest.endIndex || "/?#".contains(rest[digits.endIndex]) { return false }
        return !rest.isEmpty
    }

    /// The address to open for a computer reached at `host`, or nil when the text cannot be made
    /// into one. Without a scheme it is a web address; a file on this Mac is never opened.
    func url(host: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if usesHost {
            var h = host.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return nil }
            if h.contains(":"), !h.hasPrefix("[") { h = "[\(h)]" }     // an IPv6 address
            text = text.replacingOccurrences(of: Self.placeholder, with: h)
        }
        if !Self.hasScheme(text) { text = "http://" + text }
        guard let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), scheme != "file",
              !(c.host ?? "").isEmpty || !c.path.isEmpty else { return nil }
        return c.url
    }

    /// The port that has to answer before the link is worth opening, where the address tells;
    /// nil means any of the computer's services will do.
    func port(host: String) -> UInt16? {
        guard let u = url(host: host) else { return nil }
        if let p = u.port, let port = UInt16(exactly: p) { return port }
        switch u.scheme?.lowercased() {
        case "http":          return 80
        case "https":         return 443
        case "vnc":           return Probe.vnc
        case "ssh", "sftp":   return Probe.ssh
        case "smb":           return Probe.smb
        case "rdp":           return Probe.rdp
        default:              return nil
        }
    }
}

// MARK: - Diagnosis

/// What Hop can say about why a computer is not reachable or one of its actions is dimmed. It is
/// worked out from what the regular checks already found, never from a new connection, and it
/// says nothing Hop cannot observe: why a sign-in was refused, for one.
enum Diagnosis {
    enum TailscaleFact: Equatable { case connected, offline(Date?), notListed, notRunningHere, signedOutHere }
    enum LocalFact: Equatable { case answering(String), asleep, silent, notFound }
    enum WakeFact: Equatable { case ready, through([String]), noHelper, unknown }
    enum SleepFailure: Equatable { case signIn, refused }
    enum Action: Equatable { case openTailscale }

    struct Facts {
        var name: String
        var platform: Platform = .mac
        var hasNetwork = true
        /// Nil while the first check has not answered.
        var online: Bool?
        /// Nil for a computer without a Tailscale address, or while Tailscale has not answered.
        var tailscale: TailscaleFact?
        /// Nil while Nearby is off, and for a computer that answers at its own address.
        var local: LocalFact?
        /// Reached only through the local network.
        var routedLocally = false
        /// The ports that answered at the last check; nil when it is not online or not checked.
        var services: Set<UInt16>?
        var wake: WakeFact = .unknown
        var wakeFailed = false
        var wakeHelper: String?
        var sleepFailed: SleepFailure?
        /// The user put it to sleep from Hop, and has not connected to it since.
        var sleptOnRequest = false
    }

    struct Line: Equatable {
        let label: String
        let value: String
    }

    static func desktopService(_ p: Platform) -> String { p == .windows ? "Remote Desktop" : "Screen Sharing" }

    /// The services of an online computer that did not answer, by name, in the order they are shown.
    static func off(_ f: Facts) -> [String] {
        guard f.online == true, let open = f.services else { return [] }
        var names: [String] = []
        if !open.contains(f.platform.desktopPort) { names.append(desktopService(f.platform)) }
        if !open.contains(Probe.ssh) { names.append("SSH") }
        if !open.contains(Probe.smb) { names.append("File Sharing") }
        return names
    }

    /// Whether there is anything to explain.
    static func applies(_ f: Facts) -> Bool {
        f.online == false || f.wakeFailed || f.sleepFailed != nil || f.routedLocally || !off(f).isEmpty
    }

    static func lines(_ f: Facts, now: Date = Date()) -> [Line] {
        var lines: [Line] = []
        if let t = f.tailscale {
            let value: String
            switch t {
            case .connected:        value = "connected"
            case .offline(let seen?):
                let relative = RelativeDateTimeFormatter()
                relative.unitsStyle = .full
                relative.locale = Locale(identifier: "en_US")
                value = "offline, last seen " + relative.localizedString(for: seen, relativeTo: now)
            case .offline(nil):     value = "offline"
            case .notListed:        value = "not on your tailnet"
            case .notRunningHere:   value = "not running on this Mac"
            case .signedOutHere:    value = "signed out on this Mac"
            }
            lines.append(Line(label: "Tailscale", value: value))
        }
        if let l = f.local {
            let value: String
            switch l {
            case .answering(let host): value = "answering at \(host)"
            case .asleep:              value = "asleep, another device is answering for it"
            case .silent:              value = "found, not answering"
            case .notFound:            value = "not found"
            }
            lines.append(Line(label: "Local network", value: value))
        }
        if f.online == true, let open = f.services {
            let parts = [(desktopService(f.platform), f.platform.desktopPort), ("SSH", Probe.ssh), ("File Sharing", Probe.smb)]
            lines.append(Line(label: "Services", value: parts.map { "\($0.0) \(open.contains($0.1) ? "on" : "off")" }.joined(separator: " · ")))
        }
        let wake: String
        switch f.wake {
        case .ready:              wake = "ready"
        case .through(let names): wake = "ready, through " + names.joined(separator: ", ")
        case .noHelper:           wake = "no computer at home can pass it on"
        case .unknown:            wake = "no hardware address known"
        }
        lines.append(Line(label: "Wake", value: wake))
        return lines
    }

    /// The one sentence under the facts: the first reason that applies, most telling first.
    static func conclusion(_ f: Facts) -> (text: String, action: Action?)? {
        guard applies(f) else { return nil }
        switch f.sleepFailed {
        case .signIn?:
            return ("Hop could not sign in to \(f.name) over SSH without a question. Sleep needs SSH that works without a password.", nil)
        case .refused?:
            return ("\(f.name) did not accept the request to sleep. Its account may not be allowed to put it to sleep.", nil)
        case nil: break
        }
        if !f.hasNetwork { return ("This Mac is not connected to a network.", nil) }
        if f.online != true {
            if f.tailscale == .notRunningHere { return ("Tailscale is not running on this Mac.", .openTailscale) }
            if f.tailscale == .signedOutHere { return ("Tailscale is signed out on this Mac.", .openTailscale) }
        }
        if f.online == false, f.sleptOnRequest {
            switch f.wake {
            case .ready, .through:    return ("You put it to sleep from Hop. Connecting wakes it.", nil)
            case .noHelper, .unknown: return ("You put it to sleep from Hop. Hop cannot wake it from here.", nil)
            }
        }
        if f.online == false, f.local == .asleep { return ("It is asleep. Connecting wakes it.", nil) }
        if f.wakeFailed {
            let sent = f.wakeHelper.map { "The wake-up packet was sent through \($0)" } ?? "The wake-up packet was sent"
            return (sent + " and it did not answer. It may be powered off, on Wi-Fi only, or have Wake for network access turned off.", nil)
        }
        if f.routedLocally {
            switch f.tailscale {
            case .offline?:
                return ("Tailscale is not running on it. It may have restarted and be waiting for someone to log in.", nil)
            case .notListed?:
                return ("It is no longer on your tailnet. Hop is reaching it on the local network instead.", nil)
            default:
                return ("Its saved address does not answer. Hop is reaching it on the local network instead.", nil)
            }
        }
        let off = off(f)
        if !off.isEmpty {
            let what = off.count == 1 ? "\(off[0]) appears to be off."
                : off.dropLast().joined(separator: ", ") + " and \(off[off.count - 1]) appear to be off."
            guard f.platform == .mac else { return (what, nil) }
            return (what + " Turn \(off.count == 1 ? "it" : "them") on in System Settings › General › Sharing on that Mac.", nil)
        }
        switch f.wake {
        case .ready, .through:
            return ("It is off, asleep or on another network. Connecting tries to wake it.", nil)
        case .noHelper:
            return ("It is off, asleep or on another network. No computer at home can pass on the wake-up packet.", nil)
        case .unknown:
            return ("It is off, asleep or on another network. Hop cannot wake it without its hardware address.", nil)
        }
    }
}

// MARK: - Sleep

/// Putting a computer to sleep: one fixed command per platform, sent over `ssh` in the way that
/// never asks anything (see `Relay.options`). Nothing typed by the user reaches the other shell.
enum RemoteSleep {
    /// How long `ssh` itself gets.
    static let runLimit: Double = 10
    /// Printed by the other computer before it sleeps, so a sign-in that worked can be told from
    /// one that did not even when the connection drops as the computer goes down.
    static let marker = "hop-sleep"

    /// What the computer is asked to run: the system's own "sleep now", with no rights asked for.
    static func command(for platform: Platform) -> [String]? {
        switch platform {
        case .mac:     return ["echo", marker, "&&", "/usr/bin/pmset", "sleepnow"]
        case .linux:   return ["echo", marker, "&&", "systemctl", "suspend"]
        case .windows: return nil
        }
    }

    static func arguments(_ m: RemoteMac, configured: [SSHHost]) -> [String]? {
        guard let command = command(for: m.platform), let destination = Relay.destination(m, configured: configured) else { return nil }
        return Relay.options + destination + command
    }

    /// Whether Sleep is offered: a Mac or Linux computer that is online with SSH answering, and
    /// not in the middle of being woken or put to sleep.
    static func offered(platform: Platform, online: Bool, ssh: Bool, busy: Bool) -> Bool {
        command(for: platform) != nil && online && ssh && !busy
    }

    /// Whether to ask first: only when Hop could not wake the computer again afterwards.
    static func needsConfirmation(_ wake: Diagnosis.WakeFact) -> Bool {
        switch wake {
        case .ready, .through:   return false
        case .noHelper, .unknown: return true
        }
    }

    /// Nil when the computer took the request. Hop does not wait to see it fall silent: a Mac
    /// goes on answering for half a minute while it goes down, and one on Ethernet answers even
    /// asleep. An `ssh` that ended badly after signing in, or was cut off, lost the connection to
    /// a computer that was going down; any other status is the computer's own refusal.
    static func failure(signedIn: Bool, status: Int32, timedOut: Bool) -> Diagnosis.SleepFailure? {
        if !signedIn { return .signIn }
        if timedOut || status == 0 || status == 255 { return nil }
        return .refused
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
    /// When it was last connected; nil while it is online, and for a device that never was.
    let lastSeen: Date?
    /// The IPv4 address Tailscale reaches it at directly; nil through a relay or over IPv6.
    var localIP: String? = nil
}

/// Every device name on the tailnet, this Mac's included, and the domain they share. It tells a saved
/// address that has left the tailnet from one Hop simply does not list.
struct TailnetRoster: Equatable {
    var suffix: String          // taile7d833.ts.net
    var names: Set<String>      // full names, lower case
}

/// What a check found about a saved computer whose address is a tailnet name.
enum TailnetFate: Equatable {
    case present            // its device is on the tailnet, or the address is not a name of this tailnet
    case moved(String)      // the device now goes by this address
    case gone               // no device has the address and none stands for the computer
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
        let CurrentTailnet: Tailnet?
        let MagicDNSSuffix: String?
        let me: Peer?
        let Peer: [String: Peer]?
        enum CodingKeys: String, CodingKey { case BackendState, CurrentTailnet, MagicDNSSuffix, me = "Self", Peer }
        struct Tailnet: Decodable {
            let MagicDNSEnabled: Bool?
        }
        struct Peer: Decodable {
            let HostName: String?
            let DNSName: String?
            let OS: String?
            let Online: Bool?
            let TailscaleIPs: [String]?
            let LastSeen: String?
            let CurAddr: String?
            let ShareeNode: Bool?
            let ExitNodeOption: Bool?
            let Location: Present?

            /// Not one of the user's computers: a device another tailnet shared in, which can only
            /// connect to this one, or a server of the Mullvad add-on, of which there are hundreds.
            /// Mullvad's are known by their name, and on older clients as exit nodes with a location.
            var isLeftOut: Bool {
                if ShareeNode == true { return true }
                let dns = (DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return dns.hasSuffix(".mullvad.ts.net") || (ExitNodeOption == true && Location != nil)
            }
        }
        /// Decodes from any value that is there, whatever its shape.
        struct Present: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }

    /// How long `tailscale status` may take before it is stopped.
    static let timeout: Double = 5

    /// What the Tailscale tool finds in its environment: where the system's programs are, whose home
    /// it is, and nothing of Hop's own, which holds whatever the shell that started Hop had exported.
    ///
    /// The Tailscale app's binary is both the GUI and the command-line tool, and picks its mode from
    /// the environment. An app started from Finder or at login has a bare environment, in which the
    /// binary tries to be the GUI and prints "The Tailscale GUI failed to start" in place of the
    /// status. TAILSCALE_BE_CLI is Tailscale's switch for forcing the tool.
    ///
    /// Checked 2026-11-23 with the Tailscale app's binary: status --json answers as usual with only
    /// these three. NOT checked with a Homebrew tailscale (none was installed); it talks to its
    /// daemon over a fixed socket, so nothing more is expected to be needed.
    static var environment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TAILSCALE_BE_CLI": "1"]
    }

    /// Runs `tailscale status --json` and returns every peer on the tailnet, or nil when the tool
    /// did not answer in time and was stopped.
    static func fetch(tool: String? = nil) async -> (TailscaleState, [TailscalePeer], TailnetRoster?)? {
        guard let path = tool ?? cliPath() else { return (.notInstalled, [], nil) }
        guard let r = await Shell.run(path, ["status", "--json"], timeout: timeout, environment: environment) else {
            return (.notRunning("Couldn't run Tailscale"), [], nil)
        }
        return r.timedOut ? nil : interpret(r.out)
    }

    /// A time as Tailscale writes it: RFC 3339, with or without fractions of a second. Go's zero time
    /// (year 1), which stands for "never" and for a device that is online, gives nil.
    static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = fractional.date(from: text) ?? plain.date(from: text), d.timeIntervalSince1970 > 0 else { return nil }
        return d
    }

    /// The IPv4 address in a direct endpoint as Tailscale writes it, `192.168.1.40:41641`. An IPv6
    /// endpoint (`[fd00::1]:41641`) and an empty one, which means a relay, give nil.
    static func directIPv4(_ endpoint: String?) -> String? {
        guard let parts = endpoint?.split(separator: ":", omittingEmptySubsequences: false), parts.count == 2 else { return nil }
        let ip = String(parts[0])
        return LocalNet.ipv4(ip) == nil ? nil : ip
    }

    /// Turns the output of `tailscale status --json` into a state and the peers. No output means the
    /// Tailscale service did not answer; output that is not a status is reported as unreadable.
    static func interpret(_ data: Data) -> (TailscaleState, [TailscalePeer], TailnetRoster?) {
        do {
            guard let s = try? JSONDecoder().decode(Status.self, from: data) else {
                let blank = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
                return (.notRunning(blank ? "Tailscale isn't running" : "Couldn't read Tailscale's status"), [], nil)
            }
            guard s.BackendState == "Running" else {
                let state = s.BackendState ?? "Stopped"
                return (.notRunning(state == "NeedsLogin" ? "Sign in to Tailscale" : "Tailscale is \(state.lowercased())"), [], nil)
            }
            // The names exist either way, but they only resolve while MagicDNS is on for the tailnet.
            let magicDNS = s.CurrentTailnet?.MagicDNSEnabled ?? true
            let peers = (s.Peer ?? [:]).values.filter { !$0.isLeftOut }.map { pr -> TailscalePeer in
                let dns = (pr.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let ips = pr.TailscaleIPs ?? []
                let ip = ips.first { !$0.contains(":") } ?? ips.first ?? ""
                let online = pr.Online ?? false
                return TailscalePeer(name: pr.HostName ?? dns,
                                     host: (magicDNS && !dns.isEmpty) || ip.isEmpty ? dns : ip,
                                     os: pr.OS ?? "",
                                     online: online,
                                     ips: ips,
                                     lastSeen: online ? nil : date(pr.LastSeen),
                                     localIP: online ? directIPv4(pr.CurAddr) : nil)
            }
            .filter { !$0.host.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // Every device counts here, the ones Hop leaves out of its list too: a saved computer
            // whose device is shared in from another tailnet is still on it.
            func full(_ dns: String?) -> String? {
                let n = (dns ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return n.isEmpty ? nil : n
            }
            var roster: TailnetRoster?
            if let suffix = full(s.MagicDNSSuffix), let peerList = s.Peer, !peerList.isEmpty {
                roster = TailnetRoster(suffix: suffix, names: Set(peerList.values.compactMap { full($0.DNSName) } + [full(s.me?.DNSName)].compactMap { $0 }))
            }
            return (.running, peers, roster)
        }
    }

    /// A name with only its letters and digits, in lower case, so "sercan’s Mac mini" and
    /// "sercans-Mac-mini" read the same.
    static func plain(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A device's short name without the number Tailscale adds when the name is taken:
    /// `studio-1` and `studio` are both `studio`.
    static func base(_ host: String) -> String {
        let short = Nearby.short(host)
        guard let dash = short.lastIndex(of: "-") else { return short }
        let tail = short[short.index(after: dash)...]
        return !tail.isEmpty && tail.allSatisfy(\.isNumber) && dash != short.startIndex ? String(short[..<dash]) : short
    }

    /// What became of a saved computer. Only an address that is a full name in this tailnet's domain
    /// is judged; a short name, an IP address or another domain is left alone. When no device has the
    /// address any more, the computer is looked for among the listed devices that are not saved yet
    /// (`free`): one with the same name, or the same device name apart from Tailscale's numbering.
    /// It has moved only when exactly one fits.
    static func fate(host: String, name: String, roster: TailnetRoster, free: [TailscalePeer]) -> TailnetFate {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard h.hasSuffix("." + roster.suffix), !roster.names.contains(h) else { return .present }
        let wanted = plain(name), device = base(h)
        let fits = free.filter { p in
            p.host.lowercased().hasSuffix("." + roster.suffix)
                && ((!wanted.isEmpty && plain(p.name) == wanted) || base(p.host) == device)
        }
        return fits.count == 1 ? .moved(fits[0].host) : .gone
    }
}

// MARK: - Nearby

/// A computer found on the local network through Bonjour.
struct NearbyPeer: Hashable {
    let name: String    // the Bonjour service name, which is the computer's name
    let host: String    // its local host name, such as studio.local
    let isMac: Bool
    let vnc: Bool
    let ssh: Bool
    let smb: Bool
}

enum Nearby {
    /// A host name's first label in lower case. An IP address has no short form and is returned whole.
    static func short(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        let isIPv4 = !h.isEmpty && h.allSatisfy { $0.isNumber || $0 == "." }
        if isIPv4 || h.contains(":") { return h }
        return h.split(separator: ".").first.map(String.init) ?? h
    }

    /// Whether a device-info record is a Mac's: it carries `osxvers`, which only macOS publishes, or
    /// a model identifier of a Mac family (`Mac14,3`, `MacBookPro18,1`). Samba's `MacSamba` is neither.
    static func isMac(deviceInfo txt: [String: String]) -> Bool {
        if txt["osxvers"] != nil { return true }
        guard let model = txt["model"] else { return false }
        let families = ["MacBookPro", "MacBookAir", "MacBook", "Macmini", "MacPro", "iMacPro", "iMac", "Mac"]
        guard let family = families.first(where: { model.hasPrefix($0) }) else { return false }
        let parts = model.dropFirst(family.count).split(separator: ",", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The keys and values of a DNS TXT record: strings, each led by its length.
    static func txt(_ bytes: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < bytes.count {
            let n = Int(bytes[i])
            i += 1
            guard n > 0, i + n <= bytes.count else { break }
            if let s = String(bytes: bytes[i..<(i + n)], encoding: .utf8) {
                let kv = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                out[String(kv[0]).lowercased()] = kv.count > 1 ? String(kv[1]) : ""
            }
            i += n
        }
        return out
    }

    /// A host target as DNS-SD reports it (`Studio.local.`) without the final dot, or nil when it is
    /// not something to put in a link.
    static func host(target: String) -> String? {
        var h = target.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, !h.contains("\\"), !h.contains(" ") else { return nil }
        return h
    }

    /// The peer that is the same computer as a saved or Tailscale row: its short host name is the
    /// short name of the row's address, or its computer name is the row's name. Case is ignored.
    ///
    /// Names are compared as well because Tailscale numbers a DNS name that is already taken
    /// (sercans-macbook-pro-1), so the host names of one Mac can differ while the name it reports,
    /// "sercan’s MacBook Pro", is the same in both places. This Mac is never a match.
    static func match(_ peers: [NearbyPeer], host: String, name: String, thisHost: String) -> NearbyPeer? {
        let me = short(thisHost)
        let h = short(host)
        guard !h.isEmpty else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return peers.first { p in
            let s = short(p.host)
            guard !s.isEmpty, s != me else { return false }
            return s == h || (!n.isEmpty && p.name.trimmingCharacters(in: .whitespaces).lowercased() == n)
        }
    }

    /// The peers to list under Nearby. A Mac is listed for any of its three services, anything else
    /// only for screen sharing or remote login. This Mac is left out, and so is a computer that a
    /// saved or Tailscale row stands for, online there or not: it is listed once, in that section.
    static func listed(_ peers: [NearbyPeer], rows: [(host: String, name: String)], thisHost: String) -> [NearbyPeer] {
        let me = short(thisHost)
        let taken = Set(rows.compactMap { match(peers, host: $0.host, name: $0.name, thisHost: thisHost) })
        var seen = Set<String>()
        return peers.filter { p in
            let s = short(p.host)
            guard !s.isEmpty, s != me else { return false }
            guard p.vnc || p.ssh || (p.isMac && p.smb) else { return false }
            guard !taken.contains(p) else { return false }
            return seen.insert(s).inserted
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// This Mac's local host name, such as studio.local.
    static var thisHost: String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { return name + ".local" }
        return ProcessInfo.processInfo.hostName
    }
}

/// Browses the local network for computers that offer screen sharing, remote login or file sharing.
///
/// NWBrowser finds the services but only names them; Hop needs a host name for its links, so each
/// computer is resolved once through DNS-SD, and its device-info record is read to tell whether it is
/// a Mac. Everything here runs on `queue`, the DNS-SD callbacks included.
final class NearbyBrowser: @unchecked Sendable {
    static let types = ["_rfb._tcp", "_ssh._tcp", "_smb._tcp"]
    /// How long a computer waits for its device-info record before it is listed without one.
    static let grace: TimeInterval = 1.5

    private final class Lookup {
        weak var owner: NearbyBrowser?
        let name: String
        var ref: DNSServiceRef?
        init(owner: NearbyBrowser, name: String) { self.owner = owner; self.name = name }
    }

    private let queue = DispatchQueue(label: "io.github.sercanatalik.hop.nearby", qos: .utility)
    private let publish: @Sendable ([NearbyPeer]) -> Void
    private var browsers: [String: NWBrowser] = [:]
    private var found: [String: Set<String>] = [:]      // service type → the names advertising it
    private var hosts: [String: String] = [:]
    private var macs: [String: Bool] = [:]
    private var firstSeen: [String: Date] = [:]
    private var lookups: [String: [Lookup]] = [:]
    private var pending = false
    private var running = false
    private var last = Set<NearbyPeer>()    // what was published last, so the same list is said once

    /// `publish` is called on a private queue with the whole list each time it changes.
    init(publish: @escaping @Sendable ([NearbyPeer]) -> Void) { self.publish = publish }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            for type in Self.types { self.browse(type) }
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            for b in self.browsers.values { b.cancel() }
            self.browsers = [:]
            self.found = [:]
            for name in Array(self.firstSeen.keys) { self.forget(name) }
            self.last = []
            self.publish([])
        }
    }

    private func browse(_ type: String) {
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.running else { return }
            var names = Set<String>()
            for r in results { if case let .service(name, _, _, _) = r.endpoint { names.insert(name) } }
            self.found[type] = names
            self.reconcile()
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, self.running else { return }
            switch state {
            case .failed:
                // The system's Bonjour service went away. Drop what this type knew and look again.
                self.found[type] = []
                self.reconcile()
                self.browsers[type]?.cancel()
                self.browsers[type] = nil
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.running, self.browsers[type] == nil else { return }
                    self.browse(type)
                }
            case .waiting:
                // Local Network access is refused, or there is no network: nothing is nearby.
                self.found[type] = []
                self.reconcile()
            default: break
            }
        }
        browsers[type] = browser
        browser.start(queue: queue)
    }

    /// Brings the lookups in line with the names now advertised: forgets those that left, resolves new ones.
    private func reconcile() {
        let names = found.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for name in Array(firstSeen.keys) where !names.contains(name) { forget(name) }
        for name in names where firstSeen[name] == nil {
            firstSeen[name] = Date()
            let type = Self.types.first { found[$0]?.contains(name) == true } ?? Self.types[0]
            resolve(name, type: type)
            deviceInfo(name)
            queue.asyncAfter(deadline: .now() + Self.grace) { [weak self] in self?.changed() }
        }
        changed()
    }

    private func forget(_ name: String) {
        for l in lookups[name] ?? [] { if let ref = l.ref { DNSServiceRefDeallocate(ref) } }
        lookups[name] = nil
        hosts[name] = nil
        macs[name] = nil
        firstSeen[name] = nil
    }

    private func finish(_ lookup: Lookup) {
        if let ref = lookup.ref { DNSServiceRefDeallocate(ref); lookup.ref = nil }
        lookups[lookup.name]?.removeAll { $0 === lookup }
    }

    private func resolve(_ name: String, type: String) {
        let lookup = Lookup(owner: self, name: name)
        let reply: DNSServiceResolveReply = { _, _, _, error, _, target, _, _, _, context in
            guard let context else { return }
            let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
            guard let owner = lookup.owner else { return }
            if error == kDNSServiceErr_NoError, let target, let host = Nearby.host(target: String(cString: target)) {
                owner.hosts[lookup.name] = host
                owner.changed()
            }
            owner.finish(lookup)
        }
        var ref: DNSServiceRef?
        guard DNSServiceResolve(&ref, 0, 0, name, type, "local.", reply, Unmanaged.passUnretained(lookup).toOpaque()) == kDNSServiceErr_NoError,
              let ref else { return }
        lookup.ref = ref
        lookups[name, default: []].append(lookup)
        if DNSServiceSetDispatchQueue(ref, queue) != kDNSServiceErr_NoError { finish(lookup) }
    }

    /// Asks for the computer's device-info record. Macs publish one under their name without
    /// advertising it as a service, so it can only be asked for, not browsed.
    private func deviceInfo(_ name: String) {
        var full = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        guard DNSServiceConstructFullName(&full, name, "_device-info._tcp", "local.") == kDNSServiceErr_NoError else { return }
        let lookup = Lookup(owner: self, name: name)
        let reply: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
            guard let owner = lookup.owner else { return }
            guard error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data else {
                if error != kDNSServiceErr_NoError { owner.finish(lookup) }
                return
            }
            let bytes = [UInt8](UnsafeRawBufferPointer(start: data, count: Int(length)))
            owner.macs[lookup.name] = Nearby.isMac(deviceInfo: Nearby.txt(bytes))
            owner.changed()
            owner.finish(lookup)
        }
        var ref: DNSServiceRef?
        guard DNSServiceQueryRecord(&ref, 0, 0, full, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), reply,
                                    Unmanaged.passUnretained(lookup).toOpaque()) == kDNSServiceErr_NoError,
              let ref else { return }
        lookup.ref = ref
        lookups[name, default: []].append(lookup)
        if DNSServiceSetDispatchQueue(ref, queue) != kDNSServiceErr_NoError { finish(lookup) }
    }

    /// Publishes once for everything that changes within a third of a second.
    private func changed() {
        guard running, !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.pending = false
            guard self.running else { return }
            let now = Set(self.peers())
            guard now != self.last else { return }
            self.last = now
            self.publish(Array(now))
        }
    }

    private func peers() -> [NearbyPeer] {
        let now = Date()
        return firstSeen.compactMap { name, seen in
            guard let host = hosts[name] else { return nil }
            // Its device-info record says whether it is a Mac; wait a moment for it before going without.
            guard macs[name] != nil || now.timeIntervalSince(seen) >= Self.grace else { return nil }
            return NearbyPeer(name: name, host: host, isMac: macs[name] ?? false,
                              vnc: found["_rfb._tcp"]?.contains(name) == true,
                              ssh: found["_ssh._tcp"]?.contains(name) == true,
                              smb: found["_smb._tcp"]?.contains(name) == true)
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
    /// With an `environment`, the tool finds only that; without one it inherits Hop's. `input` is
    /// what the tool reads on its standard input; without it there is nothing to read.
    static func run(_ path: String, _ args: [String], timeout: Double, environment: [String: String]? = nil,
                    input: Data? = nil) async -> ShellResult? {
        await Task.detached(priority: .utility) { () -> ShellResult? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let environment { p.environment = environment }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let stdin = input == nil ? nil : Pipe()
            p.standardInput = stdin ?? FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            if let stdin, let input {
                // Small scripts only: well under the pipe's buffer, so this cannot block.
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
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
//   herdr-app do <command> ...  space.select / tab.new / space.new / space.rename
//   herdr --remote <target>     the terminal app, attached to a remote machine
//
// Observed with Herdr desktop 0.1.x and herdr 0.9.5:
//   `herdr-app do space.select --id <id>` prints {"ok": true} and exits 0;
//   an unknown id prints {"error": "no such space"} and exits 1.
//   `herdr-app do space.rename --id <id> --name <new>` (desktop 0.1.16) renames a space on a remote
//   machine as well: {"ok": true}, exit 0, and `ls` shows the new name at once. `--name ""` puts
//   back the name Herdr takes from the folder, with no prompt; leaving `--name` out makes Herdr ask
//   the person, so Hop always sends it. An unknown id prints {"error": "no space \"x\""}, exit 1.
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
    /// Stays the same for as long as the terminal lives: the space id and Herdr's terminal id.
    let key: String
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
    var active = false         // the space the Herdr window shows

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
        struct S: Decodable { let id: String?; let name: String?; let folder: String?; let machine: String?; let tabs: [T]?; let active: Bool? }
        struct T: Decodable { let name: String?; let terminals: [Term]? }
        struct Term: Decodable { let status: String?; let app: String?; let terminal: String? }
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
                for (n, term) in (t.terminals ?? []).enumerated() {
                    guard let raw = term.status, let state = AgentState(rawValue: raw) else { continue }
                    // Without a terminal id, fall back to where the terminal sits.
                    let key = (term.terminal?.isEmpty == false) ? "\(id)/\(term.terminal!)" : "\(id)/\(tab)/\(n)"
                    agents.append(HerdrAgent(key: key, tab: tab, app: term.app ?? "agent", state: state))
                }
            }
            out[machine, default: []].append(
                HerdrSpace(id: id, name: name, folder: folder, machine: machine, tabCount: s.tabs?.count ?? 0, agents: agents,
                           active: s.active ?? false))
        }
        return out
    }

    /// `listed` is false when `herdr-app ls` did not answer, which is not the same as no spaces.
    static func fetch() async -> (machines: [HerdrMachine], spaces: [String: [HerdrSpace]], listed: Bool) {
        guard let app = appCLI() else { return ([], [:], false) }
        var machines: [HerdrMachine] = []
        if let hc = coreCLI(), let r = await Shell.run(hc, ["machine", "ls", "--json"], timeout: 3), r.ok {
            machines = decodeMachines(r.out)
        }
        var spaces: [String: [HerdrSpace]] = [:]
        var listed = false
        if let r = await Shell.run(app, ["ls"], timeout: 3), r.ok {
            spaces = decodeSpaces(r.out)
            listed = true
        }
        return (machines, spaces, listed)
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

// MARK: - Agent notifications

/// An agent as a notification names it.
struct AgentNote: Hashable {
    let key: String
    let app: String
    let tab: String
    let spaceID: String
    let spaceName: String
    let macName: String

    var place: String { "\(spaceName) on \(macName)" }
}

/// Decides which agent state changes are worth a notification, the way ReachTracker does for Macs.
/// An agent seen for the first time is never news, whatever its state. A quiet check updates what
/// Hop believes without reporting anything, so nothing is reported late.
struct AgentTracker {
    struct Changes: Equatable {
        var waiting: [AgentNote] = []     // changed to blocked
        var finished: [AgentNote] = []    // changed to done
        var cleared: [String] = []        // keys that were blocked and no longer are, or are gone
    }

    private var states: [String: AgentState] = [:]

    /// `quietSpaces` are the spaces whose changes are recorded without being reported.
    mutating func observe(_ snapshot: [(note: AgentNote, state: AgentState)], quiet: Bool,
                          quietSpaces: Set<String> = []) -> Changes {
        var changes = Changes()
        var next: [String: AgentState] = [:]
        for (note, state) in snapshot {
            next[note.key] = state
            guard let before = states[note.key], before != state else { continue }
            if before == .blocked { changes.cleared.append(note.key) }
            guard !quiet, !quietSpaces.contains(note.spaceID) else { continue }
            if state == .blocked { changes.waiting.append(note) }
            if state == .done { changes.finished.append(note) }
        }
        for (key, before) in states where next[key] == nil && before == .blocked { changes.cleared.append(key) }
        states = next
        return changes
    }

    /// Forgets every agent, as when Herdr quits. Returns the keys that were blocked.
    mutating func reset() -> [String] {
        let blocked = states.filter { $0.value == .blocked }.map(\.key)
        states = [:]
        return blocked
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

    /// A click on an agent notification, or one of its two buttons.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let kind = info[Alerts.kindKey] as? String
        let space = info[Alerts.spaceKey] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            AppController.shared?.store.notificationChosen(kind: kind, space: space, action: action)
        }
        completionHandler()
    }
}

enum Alerts {
    private static let presenter = AlertPresenter()

    static let waitingCategory = "agent-waiting"
    static let openAction = "open"
    static let muteAction = "mute"
    static let kindKey = "kind"
    static let spaceKey = "space"
    static let summaryID = "agent-waiting-summary"
    static func waitingID(_ key: String) -> String { "agent-waiting-" + key }

    /// Set once: the delegate, and the two buttons a waiting notification carries.
    /// Notifications need a bundle; a bare binary has none.
    private static let prepared: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let c = UNUserNotificationCenter.current()
        c.delegate = presenter
        let open = UNNotificationAction(identifier: openAction, title: "Open Workspace", options: [])
        let mute = UNNotificationAction(identifier: muteAction, title: "Mute for 8 Hours", options: [])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: waitingCategory, actions: [open, mute], intentIdentifiers: [], options: [])
        ])
        return c
    }()

    private static var center: UNUserNotificationCenter? { prepared }

    /// Called at launch so a click on a notification that starts Hop still reaches the delegate.
    static func prepare() { _ = prepared }

    /// nil when Hop cannot post at all.
    static func status() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    static func request() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    static func denied() async -> Bool {
        guard let center else { return true }
        return await center.notificationSettings().authorizationStatus == .denied
    }

    /// Posting again under the same `id` replaces the earlier notification.
    static func post(title: String, subtitle: String = "", body: String, id: String? = nil,
                     category: String? = nil, info: [String: String] = [:]) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: nil))
    }

    /// Takes notifications back out of Notification Center.
    static func withdraw(_ ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
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
    @Published var hosts: [RemoteMac] = [] { didSet { save(); rebuildNearby() } }
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
    /// When each offline Tailscale device was last connected, where Tailscale says.
    @Published var lastSeen: [UUID: Date] = [:]

    // Nearby
    /// The computers found on the local network that are not saved and not already listed from Tailscale.
    @Published var nearby: [RemoteMac] = []
    @Published var showNearby: Bool = UserDefaults.standard.object(forKey: "showNearby") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showNearby, forKey: "showNearby")
            if showNearby { nearbyBrowser.start() } else { nearbyBrowser.stop(); nearbyPeers = [] }
            rebuildNearby()
        }
    }
    /// Everything the browser has found, before the list rules are applied.
    private var nearbyPeers: [NearbyPeer] = []
    private lazy var nearbyBrowser = NearbyBrowser { [weak self] peers in
        Task { @MainActor in
            guard let self, self.showNearby else { return }
            self.nearbyPeers = peers
            self.rebuildNearby()
            self.probeNearby(.timer)
            self.checkLocalRoutes()
        }
    }

    // Local network
    /// Rows reached through the local network because their own address does not answer, with the
    /// local host name each is reached at.
    @Published private(set) var localRoute: [UUID: String] = [:]
    /// The hardware addresses Hop found for each computer, by its address as listed.
    @Published private(set) var learned: Learned.Book = [:]
    private let learnedURL = Store.supportDir.appendingPathComponent("learned.json")
    private var learnedSaved = Date.distantPast
    /// Where Tailscale reaches each device directly, by the device's names and Tailscale addresses.
    private var tailnetLocalIP: [String: String] = [:]
    /// How many checks in a row found a saved computer's tailnet address gone.
    private var goneChecks: [UUID: Int] = [:]
    /// A saved computer is forgotten after this many, so one odd answer from Tailscale removes nothing.
    static let goneLimit = 3

    // Waking before a connection
    /// A wait for a computer to wake: the connection it is for, and the computer that sent the
    /// wake-up packet on its network when one did. The token tells one wait from the next.
    struct Waking {
        let action: ConnectAction
        let token: UUID
        var helper: String?
    }
    @Published private(set) var waking: [UUID: Waking] = [:]
    /// Whether a computer on a sleeping computer's network may be asked to send the wake-up packet.
    @Published var wakeThroughOthers: Bool = UserDefaults.standard.object(forKey: "wakeThroughOthers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wakeThroughOthers, forKey: "wakeThroughOthers") }
    }
    /// How long a computer woken through another one gets: it has to rejoin Tailscale as well.
    static let relayedWakeLimit: TimeInterval = 45
    /// Computers that did not answer after a wake, until their next check.
    @Published private(set) var wakeFailed: Set<UUID> = []
    /// The helper that sent the packet for a wake that failed, for saying so afterwards.
    private var wakeFailedHelper: [UUID: String] = [:]
    private var wakeTasks: [UUID: Task<Void, Never>] = [:]
    /// Rows whose local address another device is answering for while they sleep. The regular
    /// checks leave such an address alone, and the row is called asleep instead of offline.
    @Published private(set) var heldLocally: Set<UUID> = []
    /// Computers that were asked to sleep and are being watched go.
    @Published private(set) var sleeping: Set<UUID> = []
    /// Why a computer did not go to sleep, until its next check.
    @Published private(set) var sleepFailed: [UUID: Diagnosis.SleepFailure] = [:]
    /// Computers the user put to sleep from Hop. A sleeping Mac on Ethernet still accepts a
    /// connection, half waking for it, so no check can tell it from one that is awake: Hop takes
    /// its own word instead and leaves the computer alone until the user connects or refreshes.
    @Published private(set) var sleptOnRequest: Set<UUID> = []
    /// When each row was last knocked on at a local-network address.
    private var lastKnock: [UUID: Date] = [:]
    private var lastLearn = Date.distantPast
    /// What Tailscale last said about each device, by full name, short name and address.
    private var tailnetPeers: [String: (online: Bool, seen: Date?)] = [:]
    private var tailnetRoster: TailnetRoster?
    /// The network this Mac is on, as of the last check; nil when it cannot be told.
    private var hereNetwork: String?
    /// How long a woken computer gets to answer.
    static let wakeLimit: TimeInterval = 30

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

    // Agent notifications
    @Published var notifyWaiting: Bool = UserDefaults.standard.object(forKey: "agentNotifyWaiting") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyWaiting, forKey: "agentNotifyWaiting") }
    }
    @Published var notifyFinished: Bool = UserDefaults.standard.bool(forKey: "agentNotifyFinished") {
        didSet { UserDefaults.standard.set(notifyFinished, forKey: "agentNotifyFinished") }
    }
    @Published var quietWhileHerdrInFront: Bool = UserDefaults.standard.bool(forKey: "agentQuietInFront") {
        didSet { UserDefaults.standard.set(quietWhileHerdrInFront, forKey: "agentQuietInFront") }
    }
    private var agents = AgentTracker()
    private let agentLog = Logger(subsystem: "io.github.sercanatalik.hop", category: "agents")
    private let reachLog = Logger(subsystem: "io.github.sercanatalik.hop", category: "reach")
    /// The agents the summary notification in Notification Center stands for.
    private var summaryKeys = Set<String>()

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
        learned = Learned.pruned(Learned.load(learnedURL), at: Date())
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
        if showNearby { nearbyBrowser.start() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(.timer) }
        }
    }

    var configURL: URL { fileURL }
    var onlineCount: Int { (hosts + nearby + tailnet).filter { online[$0.id] == true }.count }
    var totalCount: Int { hosts.count + nearby.count + tailnet.count }

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

    /// Why a check runs: by the clock, because the panel or a window was opened, or because the
    /// user pressed Refresh.
    enum Check { case timer, opened, asked }

    /// Whether a row may be knocked on at a local-network address now. A connection to a sleeping
    /// Mac's service half wakes it, so by the clock this happens seldom; when the user is looking,
    /// at once.
    private func knockDue(_ id: UUID, _ why: Check) -> Bool {
        LocalNet.knockDue(last: lastKnock[id], now: Date(), looking: why != .timer)
    }

    func refresh(_ why: Check = .opened) {
        if why == .asked, !sleptOnRequest.isEmpty { sleptOnRequest = [] }
        let quiet = quietNextCheck
        quietNextCheck = false
        if !wakeFailed.isEmpty { wakeFailed = [] }
        if !wakeFailedHelper.isEmpty { wakeFailedHelper = [:] }
        if !sleepFailed.isEmpty { sleepFailed = [:] }
        hereNetwork = LocalNet.network(router: LocalNet.router(), networks: LocalNet.networks(), neighbours: LocalNet.neighbours())?.id
        for m in hosts where !m.host.trimmingCharacters(in: .whitespaces).isEmpty && !sleptOnRequest.contains(m.id) {
            let id = m.id, name = m.name, host = m.host.trimmingCharacters(in: .whitespaces), sshPort = m.sshPort
            let ownIsLocal = LocalNet.mayBeLocal(host), due = knockDue(id, why)
            // A computer saved by a local address is looked at when a knock is due, and not between.
            if ownIsLocal {
                guard due else { continue }
                lastKnock[id] = Date()
            }
            Task {
                // A local address another device answers for while the computer sleeps is not
                // connected to: that would wake it.
                var held = ownIsLocal ? await self.asleep(host, m) : false
                var open = held ? [:] : await Probe.services(host: host, sshPort: sshPort)
                var route: String?
                // Its own address is silent: the same computer may still answer on the local network.
                if open.isEmpty, !held, let local = self.localHost(for: m) {
                    held = await self.asleep(local, m)
                    if !held {
                        // Between knocks, one that was reached locally stays as it was found.
                        guard due else {
                            self.mark(id, held: false)
                            if self.localRoute[id] != local { self.online[id] = false; self.localRoute[id] = nil }
                            return
                        }
                        self.lastKnock[id] = Date()
                        let there = await Probe.services(host: local, sshPort: sshPort)
                        if !there.isEmpty { open = there; route = local }
                    }
                }
                let up = !open.isEmpty      // online when any service answers
                self.mark(id, held: held)
                self.online[id] = up
                if self.localRoute[id] != route { self.localRoute[id] = route }
                self.services[id] = Set(open.keys)
                self.latency[id] = open.values.min()
                self.noteReach(id, name: name, online: up, quiet: quiet)
            }
        }
        refreshTailscale(why)
        probeNearby(why)
        refreshHerdr()
        // Learning looks at what this check finds, so it follows once the answers are in. It
        // connects to local addresses, so by the clock it runs as seldom as a knock.
        guard why != .timer || Date().timeIntervalSince(lastLearn) >= LocalNet.knockGap else { return }
        lastLearn = Date()
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            learnAddresses()
        }
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
            let (machines, spaces, listed) = await Herdr.fetch()
            herdrMachines = machines
            herdrSpaces = spaces
            noteAgents(listed: listed)
        }
    }

    // MARK: Agent notifications

    /// Feeds one Herdr listing to the tracker and posts or withdraws notifications for what changed.
    private func noteAgents(listed: Bool) {
        guard listed else {
            // One missed answer changes nothing. With Herdr quit, start over, so that whatever state
            // the agents are in when it comes back is not reported as news.
            if NSRunningApplication.runningApplications(withBundleIdentifier: Herdr.bundleID).isEmpty {
                withdrawWaiting(agents.reset())
            }
            return
        }
        var snapshot: [(note: AgentNote, state: AgentState)] = []
        for b in listedSpaces {
            for a in b.space.agents {
                let note = AgentNote(key: a.key, app: a.app, tab: a.tab, spaceID: b.space.id,
                                     spaceName: b.space.name, macName: b.macName)
                snapshot.append((note, a.state))
            }
        }
        let herdrInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Herdr.bundleID
        let quiet = agentMode.resolved(at: Date()) != .on
        // Only the workspace on screen is left out: with Herdr in front you can see that one, not the rest.
        let shown = quietWhileHerdrInFront && herdrInFront
            ? Set(listedSpaces.filter { $0.space.active }.map { $0.space.id }) : []
        let changes = agents.observe(snapshot, quiet: quiet, quietSpaces: shown)
        let states = snapshot.map { "\($0.note.key)=\($0.state.rawValue)" }.joined(separator: " ")
        agentLog.info("check: \(states, privacy: .public) quiet=\(quiet) shown=\(shown.count) waiting=\(changes.waiting.count) finished=\(changes.finished.count) cleared=\(changes.cleared.count)")
        withdrawWaiting(changes.cleared)

        let waiting = notifyWaiting ? changes.waiting : []
        let finished = notifyFinished ? changes.finished : []
        guard !waiting.isEmpty || !finished.isEmpty else { return }
        whenAllowed { [weak self] in
            guard let self else { return }
            if waiting.count == 1, let a = waiting.first {
                Alerts.post(title: "\(a.app) is waiting", subtitle: a.place,
                            body: "Tab \(a.tab) needs your answer before it can continue.",
                            id: Alerts.waitingID(a.key), category: Alerts.waitingCategory,
                            info: [Alerts.kindKey: "waiting", Alerts.spaceKey: a.spaceID])
            } else if waiting.count > 1 {
                var places: [String] = []
                for a in waiting where !places.contains(a.place) { places.append(a.place) }
                self.summaryKeys = Set(waiting.map(\.key))
                Alerts.post(title: "\(waiting.count) agents are waiting", body: places.joined(separator: ", "),
                            id: Alerts.summaryID, info: [Alerts.kindKey: "summary"])
            }
            for a in finished {
                Alerts.post(title: "\(a.app) finished", subtitle: a.place, body: "Tab \(a.tab) is done.",
                            info: [Alerts.kindKey: "finished", Alerts.spaceKey: a.spaceID])
            }
        }
    }

    /// Takes back the waiting notifications of agents that no longer wait, and the summary once
    /// none of its agents does.
    private func withdrawWaiting(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        var ids = keys.map(Alerts.waitingID)
        if !summaryKeys.isEmpty {
            summaryKeys.subtract(keys)
            if summaryKeys.isEmpty { ids.append(Alerts.summaryID) }
        }
        Alerts.withdraw(ids)
    }

    /// Runs `post` when Hop may notify, asking for permission the first time there is something to say.
    private func whenAllowed(_ post: @escaping @MainActor () -> Void) {
        Task {
            let status = await Alerts.status()
            agentLog.info("posting: authorization=\(status?.rawValue ?? -1)")
            switch status {
            case .authorized?, .provisional?:
                alertsDenied = false
                post()
            case .notDetermined?:
                if await Alerts.request() { post() } else { alertsDenied = true }
            case .denied?:
                alertsDenied = true
            default:
                break
            }
        }
    }

    /// A click on an agent notification or one of its buttons.
    func notificationChosen(kind: String?, space: String?, action: String) {
        if action == Alerts.muteAction {
            mute(for: AgentStatusMode.eightHours)
        } else if kind == "summary" {
            AppController.shared?.showPopover()
        } else if let space, action == Alerts.openAction || action == UNNotificationDefaultActionIdentifier {
            Actions.herdrOpen(id: space, store: self)
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
        return (hosts + nearby + tailnet).first { $0.id == id }
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

    func refreshTailscale(_ why: Check = .opened) {
        guard showTailscale else {
            tailnet = []
            tailscaleState = .unknown
            rebuildNearby()
            return
        }
        Task {
            guard let (state, peers, roster) = await Tailscale.fetch() else {
                // The tool did not answer in time. What is listed stays; only a first check that
                // never finished has something to say.
                if tailscaleState == .unknown { tailscaleState = .notRunning("Tailscale isn't responding") }
                return
            }
            guard showTailscale else { return }
            if let roster { followTailnet(roster, peers) }
            tailnetRoster = roster
            var said: [String: (online: Bool, seen: Date?)] = [:]
            for p in peers {
                for name in [Learned.key(p.host), Nearby.short(p.host)] + p.ips { said[name] = (p.online, p.lastSeen) }
            }
            tailnetPeers = said
            // Skip peers you've already saved under "My Macs".
            let saved = Set(hosts.map { $0.host.lowercased().trimmingCharacters(in: .whitespaces) })
            let oldIDs = Dictionary(tailnet.map { ($0.host, $0.id) }, uniquingKeysWith: { a, _ in a })
            var list: [RemoteMac] = []
            var direct: [String: String] = [:]
            for p in peers {
                guard let ip = p.localIP else { continue }
                for name in [Learned.key(p.host), Nearby.short(p.host)] + p.ips { direct[name] = ip }
            }
            tailnetLocalIP = direct
            var offline: [RemoteMac] = []
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
                m.origin = .tailscale
                list.append(m)
                lastSeen[m.id] = p.lastSeen
                if sleptOnRequest.contains(m.id) {
                    online[m.id] = false    // put to sleep from Hop: taken at its word, and left alone
                } else if p.online {
                    online[m.id] = true
                    mark(m.id, held: false)
                    if localRoute[m.id] != nil { localRoute[m.id] = nil }
                } else {
                    // One reached through the local network stays as it is until that is checked below.
                    if localRoute[m.id] == nil { online[m.id] = false }
                    offline.append(m)
                }
            }
            tailscaleState = state
            tailnet = list
            rebuildNearby()     // a computer listed from the tailnet is not listed under Nearby as well
            for m in offline {
                let id = m.id
                guard let local = localHost(for: m) else {
                    online[id] = false
                    mark(id, held: false)
                    if localRoute[id] != nil { localRoute[id] = nil }
                    continue
                }
                let due = knockDue(id, why)
                Task {
                    let held = await self.asleep(local, m)
                    guard self.tailnet.contains(where: { $0.id == id }) else { return }
                    self.mark(id, held: held)
                    // Between knocks it stays as it was found.
                    if !held, !due { return }
                    if !held { self.lastKnock[id] = Date() }
                    let open = held ? [:] : await Probe.services(host: local)
                    guard self.tailnet.contains(where: { $0.id == id }) else { return }
                    self.online[id] = !open.isEmpty
                    self.localRoute[id] = open.isEmpty ? nil : local
                    if !open.isEmpty {
                        self.services[id] = Set(open.keys)
                        self.latency[id] = open.values.min()
                    }
                }
            }
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

    /// Applies the list rules to what the browser found. Rows keep their ids for as long as the
    /// computer keeps its host name, so an open detail view stays on it.
    func rebuildNearby() {
        guard showNearby, !nearbyPeers.isEmpty else {
            if !nearby.isEmpty { nearby = [] }
            return
        }
        let rows = (hosts + tailnet).map { (host: $0.host, name: $0.name) }
        let peers = Nearby.listed(nearbyPeers, rows: rows, thisHost: Nearby.thisHost)
        let oldIDs = Dictionary(nearby.map { ($0.host.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        var list: [RemoteMac] = []
        for p in peers {
            var m = RemoteMac()
            m.id = oldIDs[p.host.lowercased()] ?? UUID()
            m.name = p.name
            m.host = p.host
            m.platform = p.isMac ? .mac : .linux
            m.origin = .nearby
            list.append(m)
            // It is advertising, so it is there; unless another device is advertising for it.
            if !heldLocally.contains(m.id), !sleptOnRequest.contains(m.id) { online[m.id] = true }
        }
        if list != nearby { nearby = list }
    }

    /// Checks which services each nearby computer accepts, for dimming its buttons and its response time.
    func probeNearby(_ why: Check = .opened) {
        for m in nearby where !sleptOnRequest.contains(m.id) {
            let id = m.id, host = m.host
            // One that has never been looked at is looked at once; after that, when a knock is due.
            let due = services[id] == nil || knockDue(id, why)
            Task {
                // Asleep with another device answering for it: left alone, and said to be asleep.
                // What it accepted when it was last awake stays, so its buttons do not change.
                let held = await self.asleep(host, m)
                guard self.nearby.contains(where: { $0.id == id }) else { return }
                self.mark(id, held: held)
                if held {
                    self.online[id] = false
                    return
                }
                guard due else { return }
                self.lastKnock[id] = Date()
                let open = await Probe.services(host: host)
                guard self.nearby.contains(where: { $0.id == id }) else { return }
                self.online[id] = true
                self.services[id] = Set(open.keys)
                self.latency[id] = open.values.min()
            }
        }
    }

    private func mark(_ id: UUID, held: Bool) {
        guard held != heldLocally.contains(id) else { return }
        if held { heldLocally.insert(id) } else { heldLocally.remove(id) }
        let name = mac(id)?.name ?? "A computer"
        if held {
            reachLog.info("\(name, privacy: .public): another device answers for its local address, so it is left alone")
        } else {
            reachLog.info("\(name, privacy: .public): its local address is its own again")
        }
    }

    /// Keeps saved computers in step with the tailnet. One whose device was given a new name follows
    /// it, keeping its own name, user and addresses. One whose device is gone for `goneLimit` checks
    /// in a row is forgotten, unless it is being reached through the local network right now.
    private func followTailnet(_ roster: TailnetRoster, _ peers: [TailscalePeer]) {
        var saved = Set(hosts.map { Learned.key($0.host) })
        var forget: [UUID] = []
        for m in hosts {
            let free = peers.filter { !saved.contains(Learned.key($0.host)) && Platform(tailscaleOS: $0.os) != nil }
            switch Tailscale.fate(host: m.host, name: m.name, roster: roster, free: free) {
            case .present:
                goneChecks[m.id] = nil
            case .moved(let host):
                goneChecks[m.id] = nil
                guard let i = hosts.firstIndex(where: { $0.id == m.id }) else { continue }
                let old = Learned.key(m.host), new = Learned.key(host)
                if let addresses = learned[old], learned[new] == nil {
                    learned[new] = addresses
                    Learned.save(learned, to: learnedURL)
                }
                saved.insert(new)
                hosts[i].host = host
            case .gone:
                goneChecks[m.id, default: 0] += 1
                if goneChecks[m.id, default: 0] >= Self.goneLimit, localRoute[m.id] == nil { forget.append(m.id) }
            }
        }
        guard !forget.isEmpty else { return }
        for id in forget {
            cancelWake(id)
            goneChecks[id] = nil
            online[id] = nil
            localRoute[id] = nil
        }
        hosts.removeAll { forget.contains($0.id) }
    }

    // MARK: Local network

    /// The local host name of the nearby computer that is the same computer as a saved or Tailscale
    /// row, when it differs from the row's own address. Nil while Nearby is off.
    private func localHost(for m: RemoteMac) -> String? {
        guard showNearby, m.origin != .nearby,
              let p = Nearby.match(nearbyPeers, host: m.host, name: m.name, thisHost: Nearby.thisHost),
              Learned.key(p.host) != Learned.key(m.host) else { return nil }
        return p.host
    }

    /// The row as its actions should reach it: itself, or while it only answers on the local network,
    /// a copy with the local host name. An SSH config entry is set aside then, since it names the
    /// address that is not answering; the saved user and port still apply.
    func routed(_ m: RemoteMac) -> RemoteMac {
        guard let local = localRoute[m.id] else { return m }
        var c = m
        c.host = local
        c.sshAlias = ""
        return c
    }

    /// Whether a computer's local address is held by another device while it sleeps. Connecting to
    /// such an address makes that device wake the computer, which a routine check must not do; the
    /// address is left alone until the computer is back or the user asks to connect.
    private func asleep(_ local: String, _ m: RemoteMac) async -> Bool {
        let known = Set(wakeAddresses(for: m).map(LocalNet.format))
        guard let ip = await LocalNet.resolve(local) else { return false }
        var table = LocalNet.neighbours()
        if table[ip] == nil, LocalNet.onLink(ip, networks: LocalNet.networks()) {
            // Nothing is known about who holds the address yet. Asking costs one datagram that no
            // service listens for, where finding out by connecting would wake a sleeping computer.
            LocalNet.ask(ip)
            try? await Task.sleep(nanoseconds: 300_000_000)
            table = LocalNet.neighbours()
        }
        return LocalNet.heldByAnother(ip: ip, known: known, neighbours: table)
    }

    /// When the browser finds something new, an offline row may turn out to be on the local network.
    private func checkLocalRoutes() {
        for m in hosts + tailnet where online[m.id] == false && localRoute[m.id] == nil && !sleptOnRequest.contains(m.id) {
            guard let local = localHost(for: m), knockDue(m.id, .timer) else { continue }
            lastKnock[m.id] = Date()
            let id = m.id, sshPort = m.sshPort
            Task {
                let held = await self.asleep(local, m)
                if self.online[id] == false { self.mark(id, held: held) }
                guard !held else { return }
                let open = await Probe.services(host: local, sshPort: sshPort)
                guard !open.isEmpty, self.online[id] == false, self.mac(id) != nil else { return }
                self.online[id] = true
                self.localRoute[id] = local
                self.services[id] = Set(open.keys)
                self.latency[id] = open.values.min()
            }
        }
    }

    /// The hardware addresses found for a computer, most recently seen first.
    func learnedAddresses(for m: RemoteMac) -> [String] {
        (learned[Learned.key(m.host)] ?? []).map(\.mac)
    }

    /// Every hardware address known for a computer: the one typed in Manage Macs, then the found ones.
    func wakeAddresses(for m: RemoteMac) -> [[UInt8]] {
        var list: [[UInt8]] = []
        for text in [m.mac] + learnedAddresses(for: m) {
            if let bytes = MACAddress.parse(text), !list.contains(bytes) { list.append(bytes) }
        }
        return list
    }

    func canWake(_ m: RemoteMac) -> Bool { !wakeAddresses(for: m).isEmpty }

    func wake(_ m: RemoteMac) {
        sleptOnRequest.remove(m.id)
        let addresses = wakeAddresses(for: m)
        Actions.wake(addresses)
        relayWake(for: m, addresses: addresses) { _ in }
    }

    /// What is shown while a computer is waited on.
    func wakingText(_ id: UUID) -> String {
        guard let helper = waking[id]?.helper else { return "Waking…" }
        return "Waking through \(helper)…"
    }

    // MARK: Waking through another computer

    private func candidates(assumeReady: Bool) -> [HelperCandidate] {
        (hosts + tailnet).map { m in
            HelperCandidate(id: m.id, key: Learned.key(m.host), saved: m.origin == .saved,
                            online: assumeReady || online[m.id] == true,
                            routed: !assumeReady && localRoute[m.id] != nil,
                            ssh: assumeReady || services[m.id]?.contains(Probe.ssh) == true)
        }
    }

    /// The computers that can send a wake-up packet for this one right now, at most two.
    func helpers(for m: RemoteMac) -> [RemoteMac] {
        guard wakeThroughOthers else { return [] }
        let ids = Relay.helpers(target: Learned.key(m.host), candidates: candidates(assumeReady: false), book: learned)
        return ids.compactMap { mac($0) }
    }

    /// Every computer Hop has seen on this one's network, whether or not it could help this minute:
    /// what Manage Macs lists as "Can be woken through".
    func neighbours(of m: RemoteMac) -> [RemoteMac] {
        guard wakeThroughOthers else { return [] }
        let ids = Relay.helpers(target: Learned.key(m.host), candidates: candidates(assumeReady: true), book: learned, limit: .max)
        return ids.compactMap { mac($0) }
    }

    /// Asks the helpers to send the wake-up packet when this Mac is not on the computer's network.
    /// Each is asked on its own; `sent` is called with the name of every one that did it. Nothing
    /// is said about one that could not: the wait then simply runs as it would without a helper.
    private func relayWake(for m: RemoteMac, addresses: [[UInt8]], sent: @escaping @MainActor (String) -> Void) {
        guard wakeThroughOthers, !addresses.isEmpty,
              let network = Learned.network(of: Learned.key(m.host), in: learned) else { return }
        let here = LocalNet.network(router: LocalNet.router(), networks: LocalNet.networks(), neighbours: LocalNet.neighbours())
        guard Relay.needed(target: network.id, here: here?.id) else { return }
        let configured = SSHConfig.hosts() ?? []
        for helper in helpers(for: m) {
            guard let destination = Relay.destination(helper, configured: configured) else { continue }
            let name = helper.name
            Task {
                if await Relay.send(through: destination, addresses: addresses, broadcast: network.broadcast) { sent(name) }
            }
        }
    }

    /// Learns the hardware addresses of the listed computers that are on a local network right now.
    ///
    /// A computer's local address comes from Tailscale (where it reaches the device directly), from
    /// the nearby computer that matches it, or from its own address when that is a local one. The
    /// address has to complete a connection first: a device that answers for sleeping Macs holds
    /// their IP addresses while they sleep but cannot accept their connections, so what macOS
    /// knows about the address after a connection is the computer's own adapter.
    private func learnAddresses() {
        let networks = LocalNet.networks()
        guard !networks.isEmpty else { return }
        var targets: [(key: String, host: String, sshPort: Int)] = []
        for m in hosts + tailnet + nearby {
            let key = Learned.key(m.host)
            guard !key.isEmpty else { continue }
            if online[m.id] == true, let ip = tailnetLocalIP[key] ?? tailnetLocalIP[Nearby.short(m.host)] { targets.append((key, ip, m.sshPort)) }
            // Only one that is known to be awake: a sleeping computer is not knocked on to learn from it.
            if online[m.id] == true, let local = localHost(for: m) { targets.append((key, local, m.sshPort)) }
            if online[m.id] == true, localRoute[m.id] == nil { targets.append((key, m.host, m.sshPort)) }
        }
        guard !targets.isEmpty else { return }
        Task {
            var sightings: [(key: String, ip: String)] = []
            await withTaskGroup(of: (String, String)?.self) { group in
                for t in targets {
                    group.addTask {
                        guard let ip = await LocalNet.resolve(t.host), LocalNet.onLink(ip, networks: networks) else { return nil }
                        let open = await Probe.services(host: ip, sshPort: t.sshPort)
                        return open.isEmpty ? nil : (t.key, ip)
                    }
                }
                for await s in group { if let s { sightings.append((key: s.0, ip: s.1)) } }
            }
            guard !sightings.isEmpty else { return }
            let found = Learned.trusted(sightings, neighbours: LocalNet.neighbours(), own: LocalNet.ownAddresses())
            guard !found.isEmpty else { return }
            let now = Date()
            var book = Learned.pruned(learned, at: now)
            let here = LocalNet.network(router: LocalNet.router(), networks: networks, neighbours: LocalNet.neighbours())
            for f in found {
                // The network is noted for a sighting on the router's own subnet only.
                var net: String?, broadcast: String?
                if let here, let ip = LocalNet.ipv4(f.ip), ip & here.mask == here.address & here.mask {
                    net = here.id
                    broadcast = LocalNet.broadcast(address: here.address, mask: here.mask)
                }
                Learned.record(&book, key: f.key, mac: f.mac, ip: f.ip, at: now, net: net, broadcast: broadcast)
            }
            // The times move at every check; the list on screen and the file follow only when an
            // address or its place changed, and otherwise about once an hour.
            func shape(_ b: Learned.Book) -> [String: [String]] {
                b.mapValues { $0.map { "\($0.mac) \($0.ip) \($0.net ?? "")" } }
            }
            guard shape(book) != shape(learned) || now.timeIntervalSince(learnedSaved) > 3600 else { return }
            learned = book
            learnedSaved = now
            Learned.save(book, to: learnedURL)
        }
    }

    // MARK: Waking before a connection

    /// Runs a row's action. A computer that is offline and has a hardware address is checked once
    /// more, then woken, and the connection opens when the service asked for answers; the panel
    /// stays open meanwhile. Anything else connects at once, as it always did.
    func connect(_ action: ConnectAction, _ m: RemoteMac) {
        cancelWake(m.id)
        sleptOnRequest.remove(m.id)     // connecting wakes it: it is checked again from here on
        let addresses = wakeAddresses(for: m)
        guard online[m.id] == false, !addresses.isEmpty else {
            Popover.close()
            Actions.open(action, routed(m))
            return
        }
        let id = m.id, token = UUID()
        if wakeFailed.contains(id) { wakeFailed.remove(id) }
        waking[id] = Waking(action: action, token: token, helper: nil)
        wakeTasks[id] = Task {
            var target = await answering(action, m)
            if target == nil, !Task.isCancelled {
                Actions.wake(addresses)
                relayWake(for: m, addresses: addresses) { name in
                    // The first helper to send it is the one named, and only for this wait.
                    if self.waking[id]?.token == token, self.waking[id]?.helper == nil { self.waking[id]?.helper = name }
                }
                let started = Date()
                while target == nil {
                    let limit = waking[id]?.helper == nil ? Self.wakeLimit : Self.relayedWakeLimit
                    let left = limit - Date().timeIntervalSince(started)
                    guard left > 0 else { break }
                    try? await Task.sleep(nanoseconds: UInt64(min(2, left) * 1_000_000_000))
                    if Task.isCancelled { return }
                    target = await answering(action, m)
                }
            }
            guard !Task.isCancelled else { return }
            let helper = waking[id]?.helper
            waking[id] = nil
            wakeTasks[id] = nil
            guard let target else {
                wakeFailed.insert(id)
                wakeFailedHelper[id] = helper
                NSSound.beep()
                return
            }
            online[id] = true
            mark(id, held: false)
            Popover.close()
            Actions.open(action, target)
            refresh()
        }
    }

    /// Stops waiting for a computer to wake; nothing is opened.
    func cancelWake(_ id: UUID) {
        wakeTasks[id]?.cancel()
        wakeTasks[id] = nil
        if waking[id] != nil { waking[id] = nil }
    }

    func cancelAllWakes() { for id in Array(waking.keys) { cancelWake(id) } }

    /// The row to connect to once the service for an action answers, at its own address or at the
    /// local one, or nil while neither does. A Mac accepts SSH some seconds before Screen Sharing,
    /// so it is the port of the action asked for that counts.
    private func answering(_ action: ConnectAction, _ m: RemoteMac) async -> RemoteMac? {
        let port: UInt16?
        switch action {
        case .desktop: port = m.platform.desktopPort
        case .ssh:     port = (1...65535).contains(m.sshPort) ? UInt16(m.sshPort) : Probe.ssh
        case .files:   port = Probe.smb
        case .link(let link): port = link.port(host: m.host)    // nil: any service will do
        }
        let host = m.host.trimmingCharacters(in: .whitespaces)
        let local = localHost(for: m)
        async let own = Store.answers(host, port)
        async let near = Store.answers(local, port)
        let (here, there) = await (own, near)
        if here {
            if localRoute[m.id] != nil { localRoute[m.id] = nil }
            return m
        }
        if there, let local {
            localRoute[m.id] = local
            return routed(m)
        }
        return nil
    }

    private nonisolated static func answers(_ host: String?, _ port: UInt16?) async -> Bool {
        guard let host else { return false }
        guard let port else { return !(await Probe.services(host: host)).isEmpty }
        return await Probe.tcp(host: host, port: port, timeout: 1.5)
    }

    // MARK: Diagnosis

    /// "Online", "Asleep", "Offline" or "Checking". Asleep is said only on evidence: another device
    /// is answering for the computer's local address.
    func stateWord(_ m: RemoteMac) -> String {
        switch online[m.id] {
        case true?:  return "Online"
        case false?: return heldLocally.contains(m.id) || sleptOnRequest.contains(m.id) ? "Asleep" : "Offline"
        case nil:    return "Checking"
        }
    }

    /// What Tailscale has to say about a row, or nil when it has no Tailscale address.
    private func tailscaleFact(_ m: RemoteMac) -> Diagnosis.TailscaleFact? {
        guard showTailscale else { return nil }
        let key = Learned.key(m.host)
        let peer = tailnetPeers[key] ?? tailnetPeers[Nearby.short(m.host)]
        let underSuffix = tailnetRoster.map { key.hasSuffix("." + $0.suffix) } ?? false
        // Tailscale hands out addresses from 100.64.0.0/10.
        let ownRange = LocalNet.ipv4(key).map { $0 >> 22 == (100 << 2 | 1) } ?? false
        guard m.origin == .tailscale || peer != nil || underSuffix || key.hasSuffix(".ts.net") || ownRange else { return nil }
        switch tailscaleState {
        case .unknown:
            return nil
        case .notInstalled:
            return .notRunningHere
        case .notRunning(let message):
            return message.lowercased().contains("sign in") ? .signedOutHere : .notRunningHere
        case .running:
            if let peer { return peer.online ? .connected : .offline(peer.seen) }
            if let roster = tailnetRoster, underSuffix, !roster.names.contains(key) { return .notListed }
            return nil
        }
    }

    private func localFact(_ m: RemoteMac) -> Diagnosis.LocalFact? {
        guard showNearby else { return nil }
        let up = online[m.id] == true
        if !up, heldLocally.contains(m.id) { return .asleep }
        if up, let local = localRoute[m.id] { return .answering(local) }
        if m.origin == .nearby { return up ? .answering(m.host) : .silent }
        if up { return nil }      // it answers at its own address: nothing to add
        let found = Nearby.match(nearbyPeers, host: m.host, name: m.name, thisHost: Nearby.thisHost) != nil
        return found ? .silent : .notFound
    }

    /// Whether Hop could wake a computer from where this Mac is now, and through whom.
    func wakeFact(_ m: RemoteMac) -> Diagnosis.WakeFact {
        guard canWake(m) else { return .unknown }
        guard let network = Learned.network(of: Learned.key(m.host), in: learned),
              Relay.needed(target: network.id, here: hereNetwork), wakeThroughOthers else { return .ready }
        let names = helpers(for: m).map(\.name)
        return names.isEmpty ? .noHelper : .through(names)
    }

    /// Everything the diagnosis says about a row, from what the checks already found.
    func facts(for m: RemoteMac) -> Diagnosis.Facts {
        var f = Diagnosis.Facts(name: m.name, platform: m.platform)
        f.hasNetwork = hasNetwork
        f.online = online[m.id]
        f.tailscale = tailscaleFact(m)
        f.local = localFact(m)
        f.routedLocally = online[m.id] == true && localRoute[m.id] != nil
        f.services = online[m.id] == true ? services[m.id] : nil
        f.wake = wakeFact(m)
        f.wakeFailed = wakeFailed.contains(m.id)
        f.wakeHelper = wakeFailedHelper[m.id]
        f.sleepFailed = sleepFailed[m.id]
        f.sleptOnRequest = sleptOnRequest.contains(m.id)
        return f
    }

    // MARK: Sleep

    func canSleep(_ m: RemoteMac) -> Bool {
        RemoteSleep.offered(platform: m.platform, online: online[m.id] == true,
                            ssh: services[m.id]?.contains(Probe.ssh) == true,
                            busy: waking[m.id] != nil || sleeping.contains(m.id))
    }

    /// Hop asks first when it would have no way to wake the computer again.
    func sleepNeedsConfirmation(_ m: RemoteMac) -> Bool { RemoteSleep.needsConfirmation(wakeFact(m)) }

    /// Asks a computer to sleep over SSH. Once it has taken the request it is shown as asleep and
    /// left out of the checks, until the user connects to it or presses Refresh.
    func sleep(_ m: RemoteMac) {
        let target = routed(m)
        guard canSleep(m), let arguments = RemoteSleep.arguments(target, configured: SSHConfig.hosts() ?? []) else {
            NSSound.beep()
            return
        }
        let id = m.id
        if sleepFailed[id] != nil { sleepFailed[id] = nil }
        sleeping.insert(id)
        Task {
            let result = await Shell.run("/usr/bin/ssh", arguments, timeout: RemoteSleep.runLimit)
            let signedIn = result.map { String(decoding: $0.out, as: UTF8.self).contains(RemoteSleep.marker) } ?? false
            sleeping.remove(id)
            reachLog.info("Sleep for \(m.name, privacy: .public): signed in \(signedIn), ssh status \(result?.status ?? -1)")
            if let failure = RemoteSleep.failure(signedIn: signedIn, status: result?.status ?? -1, timedOut: result?.timedOut ?? false) {
                sleepFailed[id] = failure
                NSSound.beep()
                return
            }
            sleptOnRequest.insert(id)
            online[id] = false
            if localRoute[id] != nil { localRoute[id] = nil }
        }
    }

    // MARK: Links

    /// The links of a saved computer that can be opened, in the order entered.
    func links(for m: RemoteMac) -> [HostLink] {
        guard m.origin == .saved else { return [] }
        return m.links.prefix(HostLink.limit).filter { $0.complete && $0.url(host: "host.example") != nil }
    }

    /// Opens a link. One that points at the computer itself is a connection like any other, so an
    /// offline computer is woken first; one that points elsewhere opens at once.
    func open(_ link: HostLink, on m: RemoteMac) {
        guard let url = link.url(host: routed(m).host), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            NSSound.beep()
            return
        }
        if link.usesHost {
            connect(.link(link), m)
        } else {
            Popover.close()
            NSWorkspace.shared.open(url)
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

    /// Copies a Tailscale device or a nearby computer into "My Macs" so you can rename it, set a user, etc.
    @discardableResult
    func pin(_ m: RemoteMac) -> UUID {
        var c = m
        c.id = UUID()
        c.origin = .saved
        online[c.id] = online[m.id]
        services[c.id] = services[m.id]
        latency[c.id] = latency[m.id]
        localRoute[c.id] = localRoute[m.id]
        hosts.append(c)
        tailnet.removeAll { $0.id == m.id }
        nearby.removeAll { $0.id == m.id }
        return c.id
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        online[id] = nil
        refreshTailscale()
        if sshConfigHosts != nil { refreshSSHConfig() }
    }
}

// MARK: - Local network

/// What Hop works out about the networks this Mac is attached to, for learning hardware addresses.
enum LocalNet {
    /// An IPv4 address in dotted form as a number, most significant byte first, or nil.
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var n: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let byte = UInt32(part), byte <= 255 else { return nil }
            n = n << 8 | byte
        }
        return n
    }

    /// The IPv4 networks this Mac is attached to and can broadcast on, each as address and mask.
    /// Tunnels and loopback are left out, by the same test Wake-on-LAN uses.
    static func networks() -> [(address: UInt32, mask: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(address: UInt32, mask: UInt32)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = p.pointee.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if m != 0 { found.append((a, m)) }
        }
        return found
    }

    /// The broadcast address of a network, in dotted form.
    static func broadcast(address: UInt32, mask: UInt32) -> String { dotted(address | ~mask) }

    static func dotted(_ n: UInt32) -> String { "\(n >> 24).\(n >> 16 & 0xff).\(n >> 8 & 0xff).\(n & 0xff)" }

    /// The IP address of the router of this Mac's primary network, as the system has it.
    static func router() -> String? {
        guard let info = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = info["Router"] as? String, ipv4(router) != nil else { return nil }
        return router
    }

    /// The network a router stands for: its hardware address, which tells two networks apart even
    /// when both use 192.168.1.x, and the address and mask of the network it is on. Nil when the
    /// router is not known, is on none of the networks, or has no entry in the neighbour table.
    static func network(router: String?, networks: [(address: UInt32, mask: UInt32)], neighbours: [String: String])
        -> (id: String, address: UInt32, mask: UInt32)? {
        guard let router, let ip = ipv4(router), let id = neighbours[router],
              let net = networks.first(where: { ip & $0.mask == $0.address & $0.mask }) else { return nil }
        return (id, net.address, net.mask)
    }

    /// Whether an address is on one of those networks and is a computer's: not this Mac's own
    /// address there, and neither the network's address nor its broadcast address.
    static func onLink(_ ip: String, networks: [(address: UInt32, mask: UInt32)]) -> Bool {
        guard let n = ipv4(ip) else { return false }
        return networks.contains { net in
            n & net.mask == net.address & net.mask && n != net.address
                && n != net.address & net.mask && n != net.address | ~net.mask
        }
    }

    /// The hardware addresses of this Mac's own adapters, in the form `format` writes.
    static func ownAddresses() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found = Set<String>()
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_LINK) else { continue }
            let bytes: [UInt8] = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                let n = Int(dl.pointee.sdl_nlen), a = Int(dl.pointee.sdl_alen)
                guard a == 6 else { return [] }
                return withUnsafePointer(to: &dl.pointee.sdl_data) { data in
                    data.withMemoryRebound(to: UInt8.self, capacity: n + a) { Array(UnsafeBufferPointer(start: $0 + n, count: a)) }
                }
            }
            if bytes.count == 6 { found.insert(format(bytes)) }
        }
        return found
    }

    /// A hardware address the way Hop stores and shows it: aa:bb:cc:dd:ee:ff.
    static func format(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Whether a hardware address can be a computer's adapter: six bytes, not all zero, not a
    /// broadcast or multicast address (the low bit of the first byte), and not one of this Mac's.
    static func acceptable(_ bytes: [UInt8], own: Set<String>) -> Bool {
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else { return false }
        return !own.contains(format(bytes))
    }

    /// The pairs in the system's neighbour table, IP address to hardware address, as the routing
    /// sysctl returns it: a run of messages, each a header followed by the IP address (sockaddr_in)
    /// and the link-layer address (sockaddr_dl), padded to four bytes. Entries still being looked up
    /// have no hardware address yet and are left out.
    static func neighbours(table: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        let header = MemoryLayout<rt_msghdr>.size
        var at = 0
        table.withUnsafeBytes { raw in
            while at + header <= raw.count {
                let length = Int(raw.loadUnaligned(fromByteOffset: at, as: rt_msghdr.self).rtm_msglen)
                guard length >= header, at + length <= raw.count else { break }
                defer { at += length }
                let ipAt = at + header
                guard ipAt + MemoryLayout<sockaddr_in>.size <= at + length else { continue }
                let sin = raw.loadUnaligned(fromByteOffset: ipAt, as: sockaddr_in.self)
                guard sin.sin_family == sa_family_t(AF_INET) else { continue }
                let linkAt = ipAt + ((max(Int(sin.sin_len), 1) + 3) & ~3)
                guard linkAt + 8 <= at + length, raw[linkAt + 1] == UInt8(AF_LINK) else { continue }
                // sockaddr_dl: length, family, index (2), type, name length, address length, selector length, data
                let nameLength = Int(raw[linkAt + 5]), addressLength = Int(raw[linkAt + 6])
                let dataAt = linkAt + 8 + nameLength
                guard addressLength == 6, dataAt + 6 <= at + length else { continue }
                let n = UInt32(bigEndian: sin.sin_addr.s_addr)
                out["\(n >> 24).\(n >> 16 & 0xff).\(n >> 8 & 0xff).\(n & 0xff)"] = format(Array(raw[dataAt..<dataAt + 6]))
            }
        }
        return out
    }

    /// Whether an IP address is being answered for by a device other than the computer it belongs
    /// to. A device that stands in for sleeping Macs holds each of their addresses with its own
    /// adapter, so its hardware address shows up behind more than one IP address; `known` are the
    /// hardware addresses of the computer itself, which never count against it.
    static func heldByAnother(ip: String, known: Set<String>, neighbours: [String: String]) -> Bool {
        guard let mac = neighbours[ip], !known.contains(mac) else { return false }
        return neighbours.contains { $0.key != ip && $0.value == mac }
    }

    /// How far apart Hop connects to a computer's local-network address by itself.
    static let knockGap: TimeInterval = 300

    /// Whether a knock is due: at once while the user is looking, otherwise `knockGap` after the last.
    static func knockDue(last: Date?, now: Date, looking: Bool) -> Bool {
        guard !looking, let last else { return true }
        return now.timeIntervalSince(last) >= knockGap
    }

    /// Whether a saved address is one on a local network by its looks: a Bonjour name or an IPv4
    /// address. Only such an address can be held by another device, so only it is worth asking about.
    static func mayBeLocal(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h.hasSuffix(".local") || h.hasSuffix(".local.") || ipv4(h) != nil
    }

    /// Makes macOS find out who holds a local IP address, without connecting to anything there:
    /// one empty datagram to a port nothing listens on. The answer shows up in `neighbours()`.
    static func ask(_ ip: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = UInt16(33434).bigEndian
        guard inet_pton(AF_INET, ip, &to.sin_addr) == 1 else { return }
        _ = withUnsafePointer(to: &to) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, nil, 0, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// What macOS currently knows about its neighbours on the local networks.
    ///
    /// Checked on macOS 27.2: the table is only there for an app that is allowed to use the local
    /// network. Inside Hop this read returned it; the same read from a command-line program came
    /// back empty, and so did `arp -an` when Hop ran it as a child process.
    static func neighbours() -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var table = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &table, &size, nil, 0) == 0 else { return [:] }
        return neighbours(table: Array(table.prefix(size)))
    }

    /// The first IPv4 address a host name resolves to, or the text itself when it already is one.
    static func resolve(_ host: String) async -> String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if ipv4(h) != nil { return h }
        guard !h.isEmpty, !h.contains(":") else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(h, nil, &hints, &res) == 0, let first = res else { return nil }
            defer { freeaddrinfo(res) }
            guard let sa = first.pointee.ai_addr else { return nil }
            let n = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return "\(n >> 24).\(n >> 16 & 0xff).\(n >> 8 & 0xff).\(n & 0xff)"
        }.value
    }
}

/// A hardware address Hop found for a computer, with where and when it was last seen there.
struct LearnedAddress: Codable, Hashable {
    var mac: String
    var ip: String
    var seen: Date
    /// The network it was seen on, known by its router's hardware address. Absent for a sighting
    /// made before networks were recorded, or on a network that is not this Mac's primary one.
    var net: String? = nil
    /// That network's broadcast address.
    var broadcast: String? = nil
}

/// The hardware addresses Hop has learned, by computer. A computer is known by its address as it is
/// listed, so a Tailscale device and the saved Mac made from it share what was learned.
enum Learned {
    typealias Book = [String: [LearnedAddress]]

    /// How many addresses are kept per computer: enough for Ethernet, Wi-Fi and one that rotated.
    static let keep = 3
    /// A computer not seen for this long is forgotten.
    static let expiry: TimeInterval = 90 * 24 * 3600

    static func key(_ host: String) -> String { host.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Notes a sighting: the address moves to the front, and the oldest beyond `keep` are dropped.
    static func record(_ book: inout Book, key: String, mac: String, ip: String, at date: Date,
                       net: String? = nil, broadcast: String? = nil) {
        guard !key.isEmpty else { return }
        var list = (book[key] ?? []).filter { $0.mac != mac }
        list.insert(LearnedAddress(mac: mac, ip: ip, seen: date, net: net, broadcast: broadcast), at: 0)
        book[key] = Array(list.prefix(keep))
    }

    /// The network a computer is on, as far as Hop knows: that of its most recent sighting. A
    /// laptop last seen somewhere else is on that network, not on the one it was seen on before.
    static func network(of key: String, in book: Book) -> (id: String, broadcast: String?)? {
        guard let latest = book[key]?.first, let net = latest.net else { return nil }
        return (net, latest.broadcast)
    }

    /// The book without the computers last seen more than `expiry` ago.
    static func pruned(_ book: Book, at date: Date) -> Book {
        book.filter { _, list in list.contains { date.timeIntervalSince($0.seen) < expiry } }
    }

    /// The sightings worth recording from one check. A hardware address found at more than one IP
    /// address is not a computer's own (a device answering for sleeping Macs looks like that), so it
    /// is left out everywhere.
    static func trusted(_ sightings: [(key: String, ip: String)], neighbours: [String: String], own: Set<String>)
        -> [(key: String, ip: String, mac: String)] {
        var found: [(key: String, ip: String, mac: String)] = []
        var ips: [String: Set<String>] = [:]
        for s in sightings {
            guard let mac = neighbours[s.ip], let bytes = MACAddress.parse(mac), LocalNet.acceptable(bytes, own: own) else { continue }
            found.append((s.key, s.ip, mac))
            ips[mac, default: []].insert(s.ip)
        }
        return found.filter { ips[$0.mac]?.count == 1 }
    }

    static func load(_ url: URL) -> Book {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Book.self, from: data)) ?? [:]
    }

    static func save(_ book: Book, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(book) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Waking through another computer

/// What Hop knows about a listed computer when it looks for one that can send a wake-up packet.
struct HelperCandidate {
    let id: UUID
    let key: String         // its address as listed, the key of what was learned about it
    let saved: Bool
    let online: Bool
    let routed: Bool        // reached only through the local network, so not from elsewhere
    let ssh: Bool           // its SSH port answered at the last check
}

/// Sending the wake-up packet from a computer that is on the sleeping computer's network.
enum Relay {
    /// How many helpers are asked at once.
    static let limit = 2
    /// How long one helper gets.
    static let timeout: Double = 10

    /// The computers that can wake `target`: the ones last seen on the same network, online at
    /// their own address with SSH answering. Saved computers come first. The target never helps
    /// itself, under any name it is listed by: one that shares a hardware address with it is it.
    static func helpers(target: String, candidates: [HelperCandidate], book: Learned.Book, limit: Int = Relay.limit) -> [UUID] {
        guard let network = Learned.network(of: target, in: book) else { return [] }
        let own = Set((book[target] ?? []).map(\.mac))
        let fit = candidates.filter { c in
            guard c.key != target, c.online, !c.routed, c.ssh,
                  Learned.network(of: c.key, in: book)?.id == network.id else { return false }
            return own.isDisjoint(with: (book[c.key] ?? []).map(\.mac))
        }
        return Array((fit.filter(\.saved) + fit.filter { !$0.saved }).map(\.id).prefix(limit))
    }

    /// Whether a wake should also go through a helper: the computer's network is known and this Mac
    /// is not on it. A Mac whose own network cannot be told is taken to be somewhere else.
    static func needed(target network: String?, here: String?) -> Bool {
        guard let network else { return false }
        return here != network
    }

    /// The options that keep `ssh` from ever asking anything: it fails where it would prompt for a
    /// password or passphrase, and refuses a host whose key is not known yet without saving it.
    static let options = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                          "-o", "StrictHostKeyChecking=yes", "-o", "ServerAliveInterval=5"]

    /// Where `ssh` signs in for a row, as arguments: its SSH config entry when it has one that is
    /// still there, so the file's user, port and key apply; otherwise its address with the saved
    /// user and port. Nil for a row with no address.
    static func destination(_ m: RemoteMac, configured: [SSHHost]) -> [String]? {
        if !m.sshAlias.isEmpty, configured.contains(where: { $0.alias == m.sshAlias }) { return [m.sshAlias] }
        let host = m.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("-") else { return nil }
        let user = m.user.trimmingCharacters(in: .whitespaces)
        var args: [String] = []
        if (1...65535).contains(m.sshPort), m.sshPort != 22 { args += ["-p", String(m.sshPort)] }
        args.append(user.isEmpty || user.hasPrefix("-") ? host : "\(user)@\(host)")
        return args
    }

    /// The words the helper's shell is given: `sh -s`, which reads `script` from standard input,
    /// then each hardware address as twelve hex digits and the network's broadcast address. Both
    /// are written out by Hop from numbers, so there is nothing in them for a shell to interpret.
    static func command(addresses: [[UInt8]], broadcast: String?) -> [String] {
        var words = ["sh", "-s", "--"]
        words += addresses.filter { $0.count == 6 }.map { $0.map { String(format: "%02x", $0) }.joined() }
        if let n = broadcast.flatMap(LocalNet.ipv4) { words.append(LocalNet.dotted(n)) }
        return words
    }

    /// What the helper runs. It only sends the wake-up packet: for each hardware address, three
    /// times a quarter of a second apart, to the broadcast addresses, with whatever the helper
    /// already has. Perl is tried first: every Mac has it, while a Mac's /usr/bin/python3 may be the
    /// placeholder that offers to install developer tools, which must not be started.
    static let script = #"""
    macs=""; bc="255.255.255.255"
    for a in "$@"; do
      case "$a" in
        *.*) bc="$bc $a" ;;
        *) macs="$macs $a" ;;
      esac
    done
    [ -n "$macs" ] || exit 2
    if command -v perl >/dev/null 2>&1; then
      perl -MIO::Socket::INET -e '
        my @b = split / /, shift; my $ok = 0;
        for my $r (1..3) {
          for my $mac (@ARGV) {
            my $p = ("\xff" x 6) . (pack("H12", $mac) x 16);
            for my $b (@b) {
              my $s = IO::Socket::INET->new(Proto => "udp", PeerAddr => $b, PeerPort => 9, Broadcast => 1) or next;
              $ok = 1 if $s->send($p); close $s;
            }
          }
          select(undef, undef, undef, 0.25);
        }
        exit($ok ? 0 : 1);' "$bc" $macs 2>/dev/null && { echo sent; exit 0; }
    fi
    py=$(command -v python3 2>/dev/null)
    if [ -n "$py" ] && ! { [ "$(uname)" = Darwin ] && [ "$py" = /usr/bin/python3 ]; }; then
      "$py" -c '
    import socket, sys, time
    bs = sys.argv[1].split(); ok = False
    for r in range(3):
        for mac in sys.argv[2:]:
            p = b"\xff" * 6 + bytes.fromhex(mac) * 16
            for b in bs:
                try:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                    s.sendto(p, (b, 9)); s.close(); ok = True
                except OSError:
                    pass
        time.sleep(0.25)
    sys.exit(0 if ok else 1)' "$bc" $macs 2>/dev/null && { echo sent; exit 0; }
    fi
    for tool in wakeonlan etherwake ether-wake; do
      command -v "$tool" >/dev/null 2>&1 || continue
      ok=1
      for m in $macs; do
        "$tool" "$(echo "$m" | sed 's/../&:/g; s/:$//')" >/dev/null 2>&1 || ok=0
      done
      [ "$ok" = 1 ] && { echo sent; exit 0; }
    done
    exit 1

    """#

    /// Asks one computer to send the packet. True when it says it did.
    static func send(through destination: [String], addresses: [[UInt8]], broadcast: String?) async -> Bool {
        let args = options + destination + command(addresses: addresses, broadcast: broadcast)
        guard let r = await Shell.run("/usr/bin/ssh", args, timeout: timeout, input: Data(script.utf8)) else { return false }
        return r.ok
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
    static let siteURL = URL(string: "https://sercanatalik.github.io/hop-remote-launcher/")!
    static let repoURL = URL(string: "https://github.com/sercanatalik/hop-remote-launcher")!
    static let issuesURL = URL(string: "https://github.com/sercanatalik/hop-remote-launcher/issues/new")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - Actions

/// The three ways a row connects to its computer.
enum ConnectAction {
    case desktop, ssh, files
    /// One of the computer's own links, where its address points at the computer itself.
    case link(HostLink)
}

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
            string: "sercanatalik.github.io/hop-remote-launcher",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: HopInfo.siteURL]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Herdr

    /// Runs a Herdr desktop command, starting the app first if it isn't running, then brings Herdr forward.
    /// `launch: false` gives up when Herdr is not running; `activate: false` leaves Hop in front.
    @MainActor
    static func herdr(_ args: [String], store: Store, activate: Bool = true, launch: Bool = true) {
        guard let cli = Herdr.appCLI() else { NSSound.beep(); return }
        Task { @MainActor in
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Herdr.bundleID).isEmpty
            if !wasRunning {
                guard launch else { NSSound.beep(); return }
                activateHerdr()
            }
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
                if activate { activateHerdr() } else { store.refreshHerdr() }
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

    @MainActor static func herdrOpen(_ s: HerdrSpace, store: Store) { herdrOpen(id: s.id, store: store) }

    @MainActor static func herdrOpen(id: String, store: Store) {
        herdr(["space.select", "--id", id], store: store)
    }

    /// Renames a space and stays in Hop. The name is always sent, because Herdr asks the person when
    /// it is left out; an empty one puts back the name Herdr takes from the folder.
    @MainActor static func herdrRename(_ s: HerdrSpace, to name: String, store: Store) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != s.name else { return }
        herdr(["space.rename", "--id", s.id, "--name", trimmed], store: store, activate: false, launch: false)
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

    /// Wakes a computer: the magic packet of each of its adapters goes out on every local network,
    /// three times a quarter of a second apart, off the main thread. Only a first round that reached
    /// no network counts as a failure; once a packet has gone out, a repeat that fails is no reason
    /// to say so.
    static func wake(_ addresses: [[UInt8]]) {
        guard !addresses.isEmpty else { NSSound.beep(); return }
        let packets = addresses.map(WakeOnLAN.packet(for:))
        Task.detached(priority: .userInitiated) {
            // Every adapter's packet goes out in each round; one that got out is enough to count.
            guard packets.map(WakeOnLAN.broadcast).contains(true) else {
                await MainActor.run { NSSound.beep() }
                return
            }
            for _ in 1..<WakeOnLAN.repetitions {
                try? await Task.sleep(nanoseconds: 250_000_000)
                for packet in packets { _ = WakeOnLAN.broadcast(packet) }
            }
        }
    }

    static func open(_ action: ConnectAction, _ m: RemoteMac) {
        switch action {
        case .desktop: desktop(m)
        case .ssh:     ssh(m)
        case .files:   files(m)
        case .link(let link):
            if let u = link.url(host: m.host) { NSWorkspace.shared.open(u) } else { NSSound.beep() }
        }
    }
}

// MARK: - Wake-on-LAN

enum MACAddress {
    /// The six bytes of a hardware address, in any spelling people copy from other tools:
    /// aa:bb:cc:dd:ee:ff or AA-BB-CC-DD-EE-FF, where a group may leave out its leading zero as `arp`
    /// prints them (0:1c:b3:9:85:15); aabb.ccdd.eeff; or aabbccddeeff. Separators cannot be mixed.
    static func parse(_ text: String) -> [UInt8]? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func hex(_ g: Substring) -> Bool { !g.isEmpty && g.allSatisfy { $0.isASCII && $0.isHexDigit } }
        for separator in [":", "-"] as [Character] where s.contains(separator) {
            let groups = s.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.count == 6, groups.allSatisfy({ hex($0) && $0.count <= 2 }) else { return nil }
            return groups.compactMap { UInt8($0, radix: 16) }
        }
        var digits = s
        if s.contains(".") {
            let groups = s.split(separator: ".", omittingEmptySubsequences: false)
            guard groups.count == 3, groups.allSatisfy({ hex($0) && $0.count == 4 }) else { return nil }
            digits = groups.joined()
        }
        guard digits.count == 12, hex(Substring(digits)) else { return nil }
        let chars = Array(digits)
        return stride(from: 0, to: 12, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
    }
}

enum WakeOnLAN {
    static let repetitions = 3

    /// The magic packet for an adapter: six 0xFF bytes, then its address sixteen times.
    static func packet(for address: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += address }
        return packet
    }

    /// The interfaces worth broadcasting on: up and running, with an IPv4 address, able to broadcast,
    /// and neither loopback nor point-to-point, which rules out VPN tunnels.
    static func interfaces() -> [UInt32] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [UInt32] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(p.pointee.ifa_flags)
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            let index = if_nametoindex(p.pointee.ifa_name)
            if index != 0, !found.contains(index) { found.append(index) }
        }
        return found
    }

    /// Sends one copy of the packet to the broadcast address (UDP port 9) on every local network.
    ///
    /// 255.255.255.255 only leaves through the interface of the default route. With a VPN up, and
    /// Tailscale is one, that can be a tunnel that carries no broadcasts, and on a Mac with both
    /// Ethernet and Wi-Fi it reaches one of the two networks. Binding the socket to each interface
    /// in turn puts the packet on all of them. Returns false when no network took it.
    static func broadcast(_ packet: [UInt8]) -> Bool {
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

        func send() -> Bool {
            let sent = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    packet.withUnsafeBytes { buf in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return sent == packet.count
        }

        var delivered = false
        for var index in interfaces() {
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { continue }
            if send() { delivered = true }
        }
        var unbound: UInt32 = 0
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &unbound, socklen_t(MemoryLayout<UInt32>.size))
        // No interface took it: let the routing table choose, as Hop always used to.
        return delivered || send()
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
/// With `renaming` (the id of the workspace being renamed, shared by the rows of one Mac) the row
/// offers a pencil and turns its name into a text field.
struct WorkspaceRow: View {
    let space: HerdrSpace
    var showFolder = false
    var showSummary = true
    var compact = false
    var renaming: Binding<String?>? = nil
    @EnvironmentObject var store: Store
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @FocusState private var pencilFocused: Bool

    private var editing: Bool { renaming?.wrappedValue == space.id }

    private func startRename() {
        draft = space.name
        renaming?.wrappedValue = space.id
    }

    private func cancelRename() {
        if editing { renaming?.wrappedValue = nil }
    }

    private func saveRename() {
        guard editing else { return }
        renaming?.wrappedValue = nil
        Actions.herdrRename(space, to: draft, store: store)
    }

    private var renameForm: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField("Folder name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { saveRename() }
                    .onExitCommand { cancelRename() }
                    .accessibilityLabel("Name of workspace \(space.name)")
                Button("Cancel") { cancelRename() }
                Button("Save") { saveRename() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Return saves, Esc cancels. Leave it empty to use the folder name.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var folderText: String {
        var parts = space.folder.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Users" || parts[0] == "home" {
            parts.removeFirst(2)
            return parts.isEmpty ? "~" : "~/" + parts.joined(separator: "/")
        }
        return space.folder
    }

    var body: some View {
        if editing { renameForm } else { row }
    }

    private var row: some View {
        HStack(spacing: compact ? 4 : 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Text(space.name).lineLimit(1)
                    if renaming != nil {
                        IconButton(symbol: "pencil", label: "Rename \(space.name)", size: 18) { startRename() }
                            .focused($pencilFocused)
                            .opacity(hovering || pencilFocused ? 1 : 0)
                    }
                }
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
    /// The workspace being renamed. One for the whole block, so only one row is edited at a time,
    /// and leaving the detail view drops it.
    @State private var renaming: String?

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
                    WorkspaceRow(space: s, showFolder: true, showSummary: false, compact: true, renaming: $renaming)
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
        if store.sleeping.contains(m.id) { return "Going to sleep…" }
        if store.sleepFailed[m.id] != nil { return "Did not sleep" }
        if store.wakeFailed.contains(m.id) { return "Did not wake" }
        if store.online[m.id] == false { return store.stateWord(m) }
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
            .accessibilityAction(named: Text(m.platform.desktopName)) { store.connect(.desktop, m) }
            .accessibilityAction(named: "SSH") { store.connect(.ssh, m) }
            .accessibilityAction(named: "Files") { store.connect(.files, m) }
            if store.waking[m.id] != nil {
                // Waiting for it to wake: the wait is said and can be stopped, without hovering.
                HStack(spacing: 6) {
                    // Said in full when it fits: the name gives way first, then a long helper name.
                    Text(store.wakingText(m.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: 165, alignment: .trailing)
                        .fixedSize()
                    Button("Cancel") { store.cancelWake(m.id) }
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Cancel waking \(m.name)")
                }
                .layoutPriority(1)
            } else {
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
                            store.connect(.desktop, m)
                        }
                        .opacity(desktop == nil ? 1 : 0.35)
                        .focused($focus, equals: 1)
                        let ssh = store.sshAvailable(m)
                        IconButton(symbol: "terminal", label: ssh ? "SSH to \(m.name)" : "SSH to \(m.name). SSH appears to be off") {
                            store.connect(.ssh, m)
                        }
                        .opacity(ssh ? 1 : 0.35)
                        .focused($focus, equals: 2)
                        let files = store.filesAvailable(m)
                        IconButton(symbol: "folder",
                                   label: files ? "Open shared files on \(m.name)" : "Open shared files on \(m.name). File Sharing appears to be off") {
                            store.connect(.files, m)
                        }
                        .opacity(files ? 1 : 0.35)
                        .focused($focus, equals: 3)
                    }
                    .opacity(reveal ? 1 : 0)
                }
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
    @State private var confirmSleep = false

    private var hasHost: Bool { !m.host.trimmingCharacters(in: .whitespaces).isEmpty }
    private var offersTerminal: Bool { store.herdrTerminalInstalled && hasHost }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                let desktop = store.desktopProblem(m)
                Button { store.connect(.desktop, m) } label: {
                    Label(m.platform.desktopName, systemImage: m.platform.desktopSymbol)
                        .fixedSize().frame(maxWidth: .infinity)
                }
                .opacity(desktop == nil ? 1 : 0.45)
                .help(desktop ?? "\(m.platform.desktopName) \(m.name)")
                .accessibilityLabel(m.platform.desktopName + (desktop.map { ". \($0)" } ?? ""))
                let ssh = store.sshAvailable(m)
                Button { store.connect(.ssh, m) } label: {
                    Label("SSH", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .opacity(ssh ? 1 : 0.45)
                .help(ssh ? "SSH to \(m.name)" : "SSH appears to be off on \(m.name)")
                .accessibilityLabel(ssh ? "SSH" : "SSH. SSH appears to be off")
                let files = store.filesAvailable(m)
                Button { store.connect(.files, m) } label: {
                    Label("Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .opacity(files ? 1 : 0.45)
                .help(files ? "Open shared files on \(m.name)" : "File Sharing appears to be off on \(m.name)")
                .accessibilityLabel(files ? "Files" : "Files. File Sharing appears to be off")
                let canWake = store.canWake(m)
                let canSleep = store.canSleep(m)
                if canWake || canSleep || offersTerminal || m.origin != .saved {
                    Menu {
                        if canWake {
                            Button("Wake") { store.wake(m) }
                        }
                        if canSleep {
                            Button("Sleep") {
                                if store.sleepNeedsConfirmation(m) { confirmSleep = true } else { store.sleep(m) }
                            }
                        }
                        if offersTerminal {
                            Button("Open Herdr in Terminal") { Popover.close(); Actions.herdrTerminal(m) }
                        }
                        if m.origin != .saved {
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
            if store.waking[m.id] != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.wakingText(m.id)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Cancel") { store.cancelWake(m.id) }
                }
                .accessibilityElement(children: .contain)
            }
            if store.sleeping.contains(m.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Going to sleep…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            let links = store.links(for: m)
            if !links.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(links) { link in
                        Button { store.open(link, on: m) } label: {
                            Label(link.name, systemImage: "link").lineLimit(1).frame(maxWidth: .infinity)
                        }
                        .help(link.address)
                        .accessibilityLabel("Open \(link.name) on \(m.name)")
                    }
                }
                .controlSize(.regular)
            }
            let facts = store.facts(for: m)
            if Diagnosis.applies(facts), store.waking[m.id] == nil, !store.sleeping.contains(m.id) {
                DiagnosisView(facts: facts)
            }
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
        .alert("Put \(m.name) to sleep?", isPresented: $confirmSleep) {
            Button("Sleep") { store.sleep(m) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hop cannot wake it again from here.")
        }
    }
}

/// The facts Hop has about a computer that is not fully reachable, and what they most likely mean.
struct DiagnosisView: View {
    let facts: Diagnosis.Facts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Diagnosis.lines(facts), id: \.label) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.label).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                    Text(line.value).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(line.label): \(line.value)")
            }
            if let conclusion = Diagnosis.conclusion(facts) {
                Text(conclusion.text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                if conclusion.action == .openTailscale {
                    Button("Open Tailscale") { Popover.close(); Actions.openTailscale() }
                        .controlSize(.small)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Why")
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
        store.hosts.filter(matches) + store.nearby.filter(matches)
            + (store.showTailscale ? store.tailnet.filter(matches) : [])
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
            switch n {
            case 0:  store.connect(.desktop, m)
            case 1:  store.connect(.ssh, m)
            default: store.connect(.files, m)
            }
            return true
        }
        guard mods.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !store.waking.isEmpty { store.cancelAllWakes() }
            else if filtering { nav.query = ""; nav.index = 0 } else { Popover.close() }
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
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh(.asked) }
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
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh(.asked) }
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
            IconButton(symbol: "arrow.clockwise", label: "Refresh Status") { store.refresh(.asked) }
                .keyboardShortcut("r")
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 6)
    }

    private func statusLine(_ m: RemoteMac) -> String {
        if store.waking[m.id] != nil { return store.wakingText(m.id) }
        if store.sleeping.contains(m.id) { return "Going to sleep…" }
        if store.sleepFailed[m.id] != nil { return "Did not sleep" }
        if store.wakeFailed.contains(m.id) { return "Did not wake" }
        var parts = [store.stateWord(m)]
        // Reached through the local network: that says more than where the row came from.
        let local = store.online[m.id] == true && store.localRoute[m.id] != nil
        if local { parts.append("Local network") }
        if m.origin == .tailscale && !local { parts.append("Tailscale") }
        if m.origin == .nearby { parts.append("Nearby") }
        if m.platform != .mac { parts.append(m.platform.label) }
        if let machine = store.machine(for: m) {
            parts.append(machine.state.isEmpty ? "Herdr" : "Herdr \(machine.state)")
        }
        if store.online[m.id] == true, let ms = store.latency[m.id] { parts.append("\(ms) ms") }
        if m.origin == .tailscale, store.online[m.id] == false, let seen = store.lastSeen[m.id] {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            parts.append("Last seen \(relative.localizedString(for: seen, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: List

    /// The list while text is typed: only the Macs that match, without workspaces or banners.
    @ViewBuilder
    private var filteredList: some View {
        let mine = store.hosts.filter(matches)
        let near = store.nearby.filter(matches)
        let tail = store.showTailscale ? store.tailnet.filter(matches) : []
        let chosen = highlighted?.id
        VStack(alignment: .leading, spacing: 2) {
            if mine.isEmpty && near.isEmpty && tail.isEmpty {
                Text("No Macs match “\(nav.query)”").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            if !mine.isEmpty {
                SectionLabel("My Macs")
                ForEach(mine) { m in MacRow(m: m, highlighted: m.id == chosen) { detail = m.id } }
            }
            if !near.isEmpty {
                SectionLabel("Nearby")
                ForEach(near) { m in MacRow(m: m, highlighted: m.id == chosen) { detail = m.id } }
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
            if !store.nearby.isEmpty {
                SectionLabel("Nearby")
                ForEach(store.nearby) { m in macBlock(m) }
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
            } else if store.hosts.isEmpty && store.nearby.isEmpty {
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
                if !store.nearby.isEmpty {
                    Section("Nearby") {
                        ForEach(store.nearby) { m in row(m) }
                    }
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
                    Button { store.refresh(.asked); store.refreshSSHConfig() } label: { Image(systemName: "arrow.clockwise") }
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
                        if !store.hosts[i].mac.trimmingCharacters(in: .whitespaces).isEmpty,
                           MACAddress.parse(store.hosts[i].mac) == nil {
                            Text("Not a MAC address. Use the form aa:bb:cc:dd:ee:ff.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        if let found = foundAddresses(store.hosts[i]) {
                            Text(found).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let through = wokenThrough(store.hosts[i]) {
                            Text(through).font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Platform", selection: $store.hosts[i].platform) {
                            ForEach(Platform.allCases) { p in Text(p.label).tag(p) }
                        }
                    }
                    linksSection(i)
                    Section { actions(store.hosts[i]) }
                    herdrSection(store.hosts[i])
                }
                .formStyle(.grouped)
            } else if let id = selection, let m = (store.nearby + store.tailnet).first(where: { $0.id == id }) {
                Form {
                    Section {
                        LabeledContent("Name", value: m.name)
                        LabeledContent(m.origin == .nearby ? "Address" : "Tailscale address", value: m.host)
                        LabeledContent("Status", value: store.stateWord(m))
                        if let found = foundAddresses(m) {
                            Text(found).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let through = wokenThrough(m) {
                            Text(through).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(m.origin == .nearby ? "Nearby" : "From Tailscale")
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
                    Toggle("Show nearby computers", isOn: $store.showNearby)
                    Divider()
                    Toggle("Show Tailscale devices", isOn: $store.showTailscale)
                    Toggle("Only Macs", isOn: $store.tailscaleMacsOnly)
                    Divider()
                    Toggle("Wake through other computers", isOn: $store.wakeThroughOthers)
                    Divider()
                    Button("Open Tailscale") { Actions.openTailscale() }
                } label: {
                    Label("Discovery", systemImage: "point.3.connected.trianglepath.dotted")
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
                    if store.herdrAppInstalled {
                        Divider()
                        Toggle("Notify when an agent is waiting for you", isOn: $store.notifyWaiting)
                        Toggle("Notify when an agent finishes", isOn: $store.notifyFinished)
                        Toggle("Stay quiet for the workspace open in Herdr", isOn: $store.quietWhileHerdrInFront)
                        Text("Agent notifications follow Agent status: muted or off, there are none.")
                    }
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

    /// The links of a saved computer: a name and an address each, at most eight.
    @ViewBuilder
    private func linksSection(_ i: Int) -> some View {
        Section {
            ForEach($store.hosts[i].links) { $link in
                HStack(spacing: 8) {
                    TextField("Name", text: $link.name, prompt: Text("Web"))
                        .labelsHidden().frame(width: 120)
                        .accessibilityLabel("Link name")
                    TextField("Address", text: $link.address, prompt: Text("http://{host}:5000"))
                        .labelsHidden()
                        .accessibilityLabel("Link address")
                    Button {
                        let id = link.id
                        store.hosts[i].links.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this link")
                    .accessibilityLabel("Remove link \(link.name)")
                }
                if !link.address.trimmingCharacters(in: .whitespaces).isEmpty, link.url(host: "host.example") == nil {
                    Text("Hop cannot open this address").font(.caption).foregroundStyle(.red)
                }
            }
            if store.hosts[i].links.count < HostLink.limit {
                Button("Add Link") { store.hosts[i].links.append(HostLink()) }
            }
        } header: {
            Text("Links")
        } footer: {
            Text("Shown as buttons when you open this computer. {host} stands for its address.")
        }
    }

    /// "Found automatically: …" with the hardware addresses Hop learned for a computer, or nil.
    private func foundAddresses(_ m: RemoteMac) -> String? {
        let list = store.learnedAddresses(for: m)
        return list.isEmpty ? nil : "Found automatically: " + list.joined(separator: ", ")
    }

    /// "Can be woken through: …" with the computers seen on this one's network, or nil.
    private func wokenThrough(_ m: RemoteMac) -> String? {
        let names = store.neighbours(of: m).map(\.name)
        return names.isEmpty ? nil : "Can be woken through: " + names.joined(separator: ", ")
    }

    @ViewBuilder
    private func actions(_ m: RemoteMac) -> some View {
        HStack {
            Button(m.platform.desktopName) { store.connect(.desktop, m) }
            Button("SSH") { store.connect(.ssh, m) }
            Button("Files") { store.connect(.files, m) }
            if store.canWake(m) {
                Button("Wake") { store.wake(m) }
            }
            if store.waking[m.id] != nil {
                Text(store.wakingText(m.id)).foregroundStyle(.secondary).lineLimit(1)
                Button("Cancel") { store.cancelWake(m.id) }
            } else if store.wakeFailed.contains(m.id) {
                Text("Did not wake").foregroundStyle(.secondary)
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
        Alerts.prepare()

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
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// A plain click toggles the popover; a right-click or Control-click shows the small app menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        for (title, action) in [("About Hop \(HopInfo.version)", #selector(menuAbout)),
                                ("Hop on GitHub", #selector(menuGitHub))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The menu is attached only for this click, so a plain click keeps opening the popover.
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func menuAbout() { Actions.showAbout() }
    @objc private func menuGitHub() { Actions.openGitHub() }

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
