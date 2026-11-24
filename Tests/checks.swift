// Checks for Hop's pure logic. Run with ./test.sh
//
//   ./test.sh                 the checks that need nothing but this file and Hop.swift
//   ./test.sh --live          also the ones that need a network on this computer
//   ./test.sh --relay <dest>  ask a computer over ssh to send a wake-up packet for an invented address
//   ./test.sh --script        print what a helper is asked to run
import Foundation
let live = CommandLine.arguments.contains("--live")
var fails = 0, count = 0
func check(_ what: String, _ ok: Bool) { count += 1; print(ok ? "ok  " : "FAIL", what); if !ok { fails += 1 } }
func peer(_ name: String, _ host: String, vnc: Bool = true) -> NearbyPeer { NearbyPeer(name: name, host: host, isMac: true, vnc: vnc, ssh: true, smb: false) }
let me = "this-mac.local"

// matching
let peers = [peer("Alex’s Mac mini", "Alexs-Mac-mini.local"), peer("Alex’s MacBook Pro", "Alexs-MacBook-Pro.local"),
             peer("Studio", "Studio.local"), peer("Other", "other.local"), peer("This", "this-mac.local")]
check("host names match", Nearby.match(peers, host: "alexs-mac-mini.example.ts.net", name: "Renamed", thisHost: me)?.host == "Alexs-Mac-mini.local")
check("only the name matches", Nearby.match(peers, host: "alexs-macbook-pro-1.example.ts.net", name: "Alex’s MacBook Pro", thisHost: me)?.host == "Alexs-MacBook-Pro.local")
check("saved .local", Nearby.match(peers, host: "studio.local", name: "x", thisHost: me)?.name == "Studio")
check("tailscale short + case", Nearby.match(peers, host: "STUDIO", name: "", thisHost: me)?.name == "Studio")
check("no match", Nearby.match(peers, host: "nas.example.ts.net", name: "NAS", thisHost: me) == nil)
check("this Mac never matches", Nearby.match(peers, host: "this-mac.example.ts.net", name: "This", thisHost: me) == nil)
check("empty host never matches", Nearby.match(peers, host: " ", name: "Studio", thisHost: me) == nil)

// list
var listed = Nearby.listed(peers, rows: [(host: "studio.example.ts.net", name: "studio")], thisHost: me).map(\.name)
check("offline tailscale match hidden, others listed", listed == ["Alex’s Mac mini", "Alex’s MacBook Pro", "Other"])
listed = Nearby.listed(peers, rows: [(host: "alexs-macbook-pro-1.example.ts.net", name: "Alex’s MacBook Pro"), (host: "alexs-mac-mini.example.ts.net", name: "Mini")], thisHost: me).map(\.name)
check("saved by tailscale address hidden by name and by host", listed == ["Other", "Studio"])
check("no rows: all but this Mac", Nearby.listed(peers, rows: [], thisHost: me).count == 4)

// CurAddr
func status(_ peersJSON: String) -> Data { Data("{\"BackendState\":\"Running\",\"Peer\":{\(peersJSON)}}".utf8) }
let js = "\"a\":{\"HostName\":\"direct\",\"DNSName\":\"direct.t.ts.net.\",\"OS\":\"macOS\",\"Online\":true,\"TailscaleIPs\":[\"100.64.0.1\"],\"CurAddr\":\"192.168.1.40:41641\"},"
       + "\"b\":{\"HostName\":\"relayed\",\"DNSName\":\"relayed.t.ts.net.\",\"OS\":\"macOS\",\"Online\":true,\"TailscaleIPs\":[\"100.64.0.2\"],\"CurAddr\":\"\"},"
       + "\"c\":{\"HostName\":\"six\",\"DNSName\":\"six.t.ts.net.\",\"OS\":\"macOS\",\"Online\":true,\"TailscaleIPs\":[\"100.64.0.3\"],\"CurAddr\":\"[fd00::1]:41641\"},"
       + "\"d\":{\"HostName\":\"gone\",\"DNSName\":\"gone.t.ts.net.\",\"OS\":\"macOS\",\"Online\":false,\"TailscaleIPs\":[\"100.64.0.4\"],\"CurAddr\":\"192.168.1.41:1\"},"
       + "\"e\":{\"HostName\":\"old\",\"DNSName\":\"old.t.ts.net.\",\"OS\":\"macOS\",\"Online\":true,\"TailscaleIPs\":[\"100.64.0.5\"]}"
let ps = Dictionary(uniqueKeysWithValues: Tailscale.interpret(status(js)).1.map { ($0.name, $0.localIP) })
check("direct peer yields its IP", ps["direct"] == "192.168.1.40")
check("relayed peer yields none", ps["relayed"]! == nil)
check("IPv6 endpoint yields none", ps["six"]! == nil)
check("offline peer yields none", ps["gone"]! == nil)
check("no CurAddr field yields none", ps["old"]! == nil)

// on-link and acceptance
let nets: [(address: UInt32, mask: UInt32)] = [(LocalNet.ipv4("192.168.1.170")!, LocalNet.ipv4("255.255.255.0")!)]
check("on link", LocalNet.onLink("192.168.1.196", networks: nets))
check("other subnet", !LocalNet.onLink("192.168.2.196", networks: nets))
check("tailscale address", !LocalNet.onLink("100.64.0.38", networks: nets))
check("own address", !LocalNet.onLink("192.168.1.170", networks: nets))
check("broadcast address", !LocalNet.onLink("192.168.1.255", networks: nets))
check("network address", !LocalNet.onLink("192.168.1.0", networks: nets))
check("not an address", !LocalNet.onLink("studio.local", networks: nets) && LocalNet.ipv4("1.2.3") == nil && LocalNet.ipv4("1.2.3.256") == nil)
let own: Set<String> = ["aa:00:00:aa:d0:36"]
check("accepts adapter", LocalNet.acceptable([0xaa,0x00,0x00,0x1b,0xff,0x26], own: own))
check("rejects broadcast", !LocalNet.acceptable([0xff,0xff,0xff,0xff,0xff,0xff], own: own))
check("rejects multicast", !LocalNet.acceptable([0x01,0x00,0x5e,0x00,0x00,0xfb], own: own))
check("rejects zero", !LocalNet.acceptable([0,0,0,0,0,0], own: own))
check("rejects this Mac", !LocalNet.acceptable([0xaa,0x00,0x00,0xaa,0xd0,0x36], own: own))
check("rejects short", !LocalNet.acceptable([1,2,3], own: own))
let nb = ["192.168.1.1": "aa:00:00:bd:c7:5a", "192.168.1.196": "aa:00:00:1b:ff:26"]
// a synthetic table: one complete entry, one incomplete
func entry(_ ip: [UInt8], _ mac: [UInt8]) -> [UInt8] {
    var m = [UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)
    let sin: [UInt8] = [16, UInt8(AF_INET), 0, 0] + ip + [UInt8](repeating: 0, count: 8)
    let sdl: [UInt8] = [20, UInt8(AF_LINK), 4, 0, 6, 0, UInt8(mac.count), 0] + mac + [UInt8](repeating: 0, count: 12 - mac.count)
    m += sin + sdl
    let len = UInt16(m.count)
    m[0] = UInt8(len & 0xff); m[1] = UInt8(len >> 8)
    return m
}
let table = entry([192,168,1,196], [0xaa,0x00,0x00,0x1b,0xff,0x26]) + entry([192,168,1,77], []) + entry([192,168,1,1], [0xaa,0x00,0x00,0xbd,0xc7,0x5a])
check("table parsed, incomplete entry left out", LocalNet.neighbours(table: table) == nb)
check("truncated table is safe", LocalNet.neighbours(table: Array(table.dropLast(30))).count == 1 && LocalNet.neighbours(table: [1, 2, 3]).isEmpty)
let proxied = ["192.168.1.115": "aa:00:00:63:59:a0", "192.168.1.141": "aa:00:00:63:59:a0", "192.168.1.196": "aa:00:00:1b:ff:26", "192.168.1.50": "aa:00:00:00:00:09"]
check("held: shared adapter, not the computer's", LocalNet.heldByAnother(ip: "192.168.1.115", known: ["aa:00:00:00:00:01"], neighbours: proxied))
check("held even with nothing known", LocalNet.heldByAnother(ip: "192.168.1.141", known: [], neighbours: proxied))
check("not held: its own known adapter", !LocalNet.heldByAnother(ip: "192.168.1.196", known: ["aa:00:00:1b:ff:26"], neighbours: proxied))
check("not held: unknown adapter seen once (new Wi-Fi address)", !LocalNet.heldByAnother(ip: "192.168.1.50", known: ["aa:00:00:00:00:01"], neighbours: proxied))
check("not held: no entry", !LocalNet.heldByAnother(ip: "192.168.1.9", known: [], neighbours: proxied))
if live {
    check("own addresses found", !LocalNet.ownAddresses().isEmpty)
    check("networks found", !LocalNet.networks().isEmpty)
}

// trusted
var t = Learned.trusted([("a", "192.168.1.196"), ("b", "192.168.1.1"), ("c", "192.168.1.77")], neighbours: nb, own: own)
check("two sightings trusted, unknown ip dropped", t.map(\.key).sorted() == ["a", "b"])
t = Learned.trusted([("a", "192.168.1.5"), ("b", "192.168.1.6"), ("c", "192.168.1.7")],
                    neighbours: ["192.168.1.5": "aa:00:00:00:00:01", "192.168.1.6": "aa:00:00:00:00:01", "192.168.1.7": "aa:00:00:00:00:02"], own: own)
check("one address behind two IPs is learned for neither", t.map(\.key) == ["c"])
t = Learned.trusted([("saved", "192.168.1.5"), ("tailnet", "192.168.1.5")], neighbours: ["192.168.1.5": "aa:00:00:00:00:01"], own: own)
check("same computer listed twice keeps its address", t.count == 2)

// store
var book: Learned.Book = [:]
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
for (i, mac) in ["aa:00:00:00:00:01", "aa:00:00:00:00:02", "aa:00:00:00:00:03", "aa:00:00:00:00:04"].enumerated() {
    Learned.record(&book, key: "studio.local", mac: mac, ip: "192.168.1.9", at: t0.addingTimeInterval(Double(i)))
}
check("three newest kept, newest first", book["studio.local"]!.map(\.mac) == ["aa:00:00:00:00:04", "aa:00:00:00:00:03", "aa:00:00:00:00:02"])
Learned.record(&book, key: "studio.local", mac: "aa:00:00:00:00:02", ip: "192.168.1.9", at: t0.addingTimeInterval(9))
check("seen again moves to front without duplicate", book["studio.local"]!.map(\.mac) == ["aa:00:00:00:00:02", "aa:00:00:00:00:04", "aa:00:00:00:00:03"])
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hop-learned-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let url = dir.appendingPathComponent("learned.json")
check("missing file loads empty", Learned.load(url).isEmpty)
Learned.save(book, to: url)
check("round trip", Learned.load(url) == book)
try? Data("{ not json".utf8).write(to: url)
check("damaged file loads empty", Learned.load(url).isEmpty)
check("expiry", Learned.pruned(book, at: t0.addingTimeInterval(91 * 86400)).isEmpty && Learned.pruned(book, at: t0.addingTimeInterval(89 * 86400)).count == 1)
check("key", Learned.key(" Studio.Local ") == "studio.local")
try? FileManager.default.removeItem(at: dir)


// following the tailnet
func tp(_ name: String, _ host: String) -> TailscalePeer { TailscalePeer(name: name, host: host, os: "macOS", online: true, ips: [], lastSeen: nil) }
let roster = TailnetRoster(suffix: "t.ts.net", names: ["mini-1.t.ts.net", "mini-2.t.ts.net", "book-1.t.ts.net", "shared.t.ts.net"])
let free = [tp("Alexs-Mac-mini", "mini-1.t.ts.net"), tp("other", "nas.t.ts.net")]
check("present: device on the tailnet", Tailscale.fate(host: "book-1.t.ts.net", name: "Book", roster: roster, free: free) == .present)
check("present: shared-in or this Mac counts", Tailscale.fate(host: "Shared.t.ts.net ", name: "x", roster: roster, free: free) == .present)
check("present: short name is not judged", Tailscale.fate(host: "mini", name: "x", roster: roster, free: free) == .present)
check("present: IP address is not judged", Tailscale.fate(host: "100.64.0.1", name: "x", roster: roster, free: free) == .present)
check("present: another domain is not judged", Tailscale.fate(host: "mini.other.ts.net", name: "x", roster: roster, free: free) == .present)
check("present: .local is not judged", Tailscale.fate(host: "mini.local", name: "x", roster: roster, free: free) == .present)
check("moved: renumbered device name", Tailscale.fate(host: "mini.t.ts.net", name: "Renamed by user", roster: roster, free: free) == .moved("mini-1.t.ts.net"))
check("moved: same computer name, punctuation aside", Tailscale.fate(host: "old-name.t.ts.net", name: "Alex’s Mac mini", roster: roster, free: free) == .moved("mini-1.t.ts.net"))
check("gone: nothing fits", Tailscale.fate(host: "laptop.t.ts.net", name: "Laptop", roster: roster, free: free) == .gone)
check("gone: two fit, so neither is chosen", Tailscale.fate(host: "mini.t.ts.net", name: "x", roster: roster, free: free + [tp("m", "mini-3.t.ts.net")]) == .gone)
check("gone: the only fit is already saved", Tailscale.fate(host: "mini.t.ts.net", name: "x", roster: roster, free: [free[1]]) == .gone)
check("base", Tailscale.base("studio-12.t.ts.net") == "studio" && Tailscale.base("studio.t.ts.net") == "studio" && Tailscale.base("my-mac.t.ts.net") == "my-mac" && Tailscale.base("-1") == "-1")
check("plain", Tailscale.plain("Alex’s Mac mini") == Tailscale.plain("Alexs-Mac-mini"))
let withSelf = Data("{\"BackendState\":\"Running\",\"MagicDNSSuffix\":\"t.ts.net\",\"Self\":{\"DNSName\":\"me.t.ts.net.\"},\"Peer\":{\"a\":{\"HostName\":\"a\",\"DNSName\":\"A.t.ts.net.\",\"OS\":\"macOS\",\"Online\":true,\"ShareeNode\":true}}}".utf8)
check("roster holds this Mac and left-out devices", Tailscale.interpret(withSelf).2 == TailnetRoster(suffix: "t.ts.net", names: ["me.t.ts.net", "a.t.ts.net"]))
check("no roster without peers", Tailscale.interpret(Data("{\"BackendState\":\"Running\",\"MagicDNSSuffix\":\"t.ts.net\",\"Peer\":{}}".utf8)).2 == nil)
check("no roster when stopped", Tailscale.interpret(Data("{\"BackendState\":\"Stopped\"}".utf8)).2 == nil)


// networks
check("broadcast /24", LocalNet.broadcast(address: LocalNet.ipv4("192.168.1.170")!, mask: LocalNet.ipv4("255.255.255.0")!) == "192.168.1.255")
check("broadcast /23", LocalNet.broadcast(address: LocalNet.ipv4("10.0.4.9")!, mask: LocalNet.ipv4("255.255.254.0")!) == "10.0.5.255")
check("broadcast /30", LocalNet.broadcast(address: LocalNet.ipv4("172.16.0.5")!, mask: LocalNet.ipv4("255.255.255.252")!) == "172.16.0.7")
let twoNets: [(address: UInt32, mask: UInt32)] = [(LocalNet.ipv4("192.168.1.170")!, LocalNet.ipv4("255.255.255.0")!), (LocalNet.ipv4("10.0.0.5")!, LocalNet.ipv4("255.255.255.0")!)]
let hereNet = LocalNet.network(router: "192.168.1.1", networks: twoNets, neighbours: ["192.168.1.1": "aa:00:00:bd:c7:5a"])
check("network known by router adapter", hereNet?.id == "aa:00:00:bd:c7:5a" && hereNet?.mask == LocalNet.ipv4("255.255.255.0")!)
check("no network: router not in table", LocalNet.network(router: "192.168.1.1", networks: twoNets, neighbours: [:]) == nil)
check("no network: no router", LocalNet.network(router: nil, networks: twoNets, neighbours: ["192.168.1.1": "x"]) == nil)
check("no network: router on none of them", LocalNet.network(router: "172.16.0.1", networks: twoNets, neighbours: ["172.16.0.1": "x"]) == nil)

// the network of a computer
let d0 = Date(timeIntervalSince1970: 1_800_000_000)
var nb2: Learned.Book = [:]
Learned.record(&nb2, key: "studio", mac: "aa:00:00:00:00:01", ip: "192.168.1.9", at: d0, net: "home", broadcast: "192.168.1.255")
Learned.record(&nb2, key: "nas", mac: "aa:00:00:00:00:02", ip: "192.168.1.10", at: d0.addingTimeInterval(86400), net: "home", broadcast: "192.168.1.255")
Learned.record(&nb2, key: "cabin", mac: "aa:00:00:00:00:03", ip: "192.168.1.9", at: d0, net: "cabin", broadcast: "192.168.1.255")
Learned.record(&nb2, key: "book", mac: "aa:00:00:00:00:04", ip: "192.168.1.11", at: d0, net: "home", broadcast: "192.168.1.255")
Learned.record(&nb2, key: "book", mac: "aa:00:00:00:00:05", ip: "10.1.1.4", at: d0.addingTimeInterval(7 * 86400), net: "office", broadcast: "10.1.1.255")
Learned.record(&nb2, key: "old", mac: "aa:00:00:00:00:06", ip: "192.168.1.12", at: d0)
check("same range, different router: different networks", Learned.network(of: "studio", in: nb2)?.id != Learned.network(of: "cabin", in: nb2)?.id)
check("seen on different days: same network", Learned.network(of: "studio", in: nb2)?.id == Learned.network(of: "nas", in: nb2)?.id)
check("a laptop that moved is on the latest network", Learned.network(of: "book", in: nb2)?.id == "office")
check("learned by an earlier version: no network", Learned.network(of: "old", in: nb2) == nil && Learned.network(of: "nobody", in: nb2) == nil)
let old14 = Data("{\"studio\":[{\"ip\":\"192.168.1.9\",\"mac\":\"aa:00:00:00:00:01\",\"seen\":\"2026-11-23T15:00:00Z\"}]}".utf8)
let dir2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hop-learned2-\(getpid())")
try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
let url2 = dir2.appendingPathComponent("learned.json")
try? old14.write(to: url2)
check("1.4.0 file loads, without a network", Learned.load(url2)["studio"]?.first?.mac == "aa:00:00:00:00:01" && Learned.load(url2)["studio"]?.first?.net == nil)
Learned.save(nb2, to: url2)
check("network round trip", Learned.load(url2) == nb2)
try? FileManager.default.removeItem(at: dir2)

// helpers
func cand(_ key: String, saved: Bool = true, online: Bool = true, routed: Bool = false, ssh: Bool = true) -> HelperCandidate {
    HelperCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", abs(key.hashValue) % 1_000_000))!, key: key, saved: saved, online: online, routed: routed, ssh: ssh)
}
func helperKeys(_ target: String, _ cs: [HelperCandidate], _ book: Learned.Book = nb2) -> [String] {
    let ids = Relay.helpers(target: target, candidates: cs, book: book)
    return ids.map { id in cs.first { $0.id == id }!.key }
}
check("neighbour on the same network helps", helperKeys("studio", [cand("nas")]) == ["nas"])
check("other network does not help", helperKeys("studio", [cand("cabin"), cand("book")]) == [])
check("never seen does not help", helperKeys("studio", [cand("nobody"), cand("old")]) == [])
check("offline does not help", helperKeys("studio", [cand("nas", online: false)]) == [])
check("no SSH does not help", helperKeys("studio", [cand("nas", ssh: false)]) == [])
check("reached only locally does not help", helperKeys("studio", [cand("nas", routed: true)]) == [])
check("target is not its own helper", helperKeys("studio", [cand("studio"), cand("nas")]) == ["nas"])
var twice = nb2
Learned.record(&twice, key: "studio-again", mac: "aa:00:00:00:00:01", ip: "192.168.1.9", at: d0, net: "home", broadcast: "192.168.1.255")
check("target listed twice is not its own helper", helperKeys("studio", [cand("studio-again"), cand("nas")], twice) == ["nas"])
check("target with no known network gets no helper", helperKeys("old", [cand("nas"), cand("studio")]) == [])
var three = nb2
Learned.record(&three, key: "mini", mac: "aa:00:00:00:00:07", ip: "192.168.1.13", at: d0, net: "home", broadcast: "192.168.1.255")
Learned.record(&three, key: "pi", mac: "aa:00:00:00:00:08", ip: "192.168.1.14", at: d0, net: "home", broadcast: "192.168.1.255")
check("saved first, at most two", helperKeys("studio", [cand("pi", saved: false), cand("nas"), cand("mini")], three) == ["nas", "mini"])
check("found ones when nothing saved fits", helperKeys("studio", [cand("pi", saved: false)], three) == ["pi"])

// ssh arguments and the command
func row(_ host: String, user: String = "", port: Int = 0, alias: String = "") -> RemoteMac { var m = RemoteMac(); m.host = host; m.user = user; m.sshPort = port; m.sshAlias = alias; return m }
let cfg = [SSHHost(alias: "nas", hostName: "10.0.0.2", user: "admin", port: 2222)]
check("alias row uses the alias alone", Relay.destination(row("10.0.0.2", user: "x", port: 2222, alias: "nas"), configured: cfg)! == ["nas"])
check("alias gone from the file: address, user, port", Relay.destination(row("10.0.0.2", user: "x", port: 2222, alias: "gone"), configured: cfg)! == ["-p", "2222", "x@10.0.0.2"])
check("user and default port", Relay.destination(row(" studio.t.ts.net ", user: "alex", port: 22), configured: [])! == ["alex@studio.t.ts.net"])
check("bare host", Relay.destination(row("studio.t.ts.net"), configured: [])! == ["studio.t.ts.net"])
check("no address", Relay.destination(row("  "), configured: []) == nil)
check("a host that looks like an option is refused", Relay.destination(row("-oProxyCommand=x"), configured: []) == nil)
check("a user that looks like an option is dropped", Relay.destination(row("h", user: "-l"), configured: [])! == ["h"])
check("command words", Relay.command(addresses: [[0xaa,0x00,0x00,0x1b,0xff,0x26], [1,2,3]], broadcast: "192.168.001.255") == ["sh", "-s", "--", "aa00001bff26", "192.168.1.255"])
check("command without a broadcast address", Relay.command(addresses: [[0xaa,0,0,0,0,1]], broadcast: "; rm -rf") == ["sh", "-s", "--", "aa0000000001"])
check("only hex and dotted decimals are interpolated", Relay.command(addresses: [[0xaa,0,0,0,0,1]], broadcast: "10.0.0.255").dropFirst(3).allSatisfy { $0.allSatisfy { $0.isHexDigit || $0 == "." } })
check("ssh never prompts or learns a host", Relay.options.contains("BatchMode=yes") && Relay.options.contains("StrictHostKeyChecking=yes"))

check("relay: this Mac is elsewhere", Relay.needed(target: "home", here: "office"))
check("relay: this Mac's network cannot be told", Relay.needed(target: "home", here: nil))
check("no relay: on the same network", !Relay.needed(target: "home", here: "home"))
check("no relay: the computer's network is not known", !Relay.needed(target: nil, here: "office") && !Relay.needed(target: nil, here: nil))
// links
func link(_ address: String, _ name: String = "Web") -> HostLink { HostLink(name: name, address: address) }
check("link: the host placeholder", link("http://{host}:5000").url(host: "nas.example.ts.net")?.absoluteString == "http://nas.example.ts.net:5000")
check("link: reached through the local network", link("http://{host}:5000").url(host: "nas.local")?.absoluteString == "http://nas.local:5000")
check("link: no scheme typed", link("192.168.1.1").url(host: "x")?.absoluteString == "http://192.168.1.1")
check("link: name and port without a scheme", link("nas.local:5000/admin").url(host: "x")?.absoluteString == "http://nas.local:5000/admin")
check("link: placeholder and port without a scheme", link("{host}:8080").url(host: "nas.local")?.absoluteString == "http://nas.local:8080")
check("link: another app's scheme", link("vnc://{host}:5901").url(host: "studio.local")?.absoluteString == "vnc://studio.local:5901")
check("link: a scheme without slashes", link("mailto:someone@example.com").url(host: "x")?.scheme == "mailto")
check("link: a file is refused", link("file:///etc/hosts").url(host: "x") == nil && link("FILE:///etc/hosts").url(host: "x") == nil)
check("link: empty or unreadable is refused", link("  ").url(host: "x") == nil && link("http://exa mple").url(host: "x") == nil)
check("link: placeholder with no host is refused", link("http://{host}/").url(host: " ") == nil)
check("link: IPv6 host is bracketed", link("http://{host}:5000").url(host: "fd7a::1")?.absoluteString == "http://[fd7a::1]:5000")
check("link: placeholder twice", link("http://{host}/?from={host}").url(host: "nas.local")?.absoluteString == "http://nas.local/?from=nas.local")
check("link: uses host", link("http://{host}").usesHost && !link("http://192.168.1.1").usesHost)
check("link: port to wait on", link("http://{host}:5000").port(host: "h") == 5000 && link("https://{host}").port(host: "h") == 443
      && link("{host}").port(host: "h") == 80 && link("vnc://{host}").port(host: "h") == 5900 && link("foo://{host}").port(host: "h") == nil)
check("link: complete", link("x").complete && !link("x", " ").complete && !link("", "Web").complete)

// links in the saved list
let v15 = Data("[{\"host\":\"nas.t.ts.net\",\"id\":\"11111111-2222-3333-4444-555555555555\",\"mac\":\"\",\"name\":\"NAS\",\"platform\":\"linux\",\"sshAlias\":\"\",\"sshPort\":0,\"user\":\"admin\"}]".utf8)
var savedList = try! JSONDecoder().decode([RemoteMac].self, from: v15)
check("1.5 list loads with no links", savedList.count == 1 && savedList[0].links.isEmpty && savedList[0].user == "admin" && savedList[0].platform == .linux)
let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
check("a list without links is written as before", String(decoding: try! enc.encode(savedList), as: UTF8.self) == String(decoding: v15, as: UTF8.self))
savedList[0].links = [link("http://{host}:5000"), link("", "No address"), link("http://x", " ")]
let again = try! JSONDecoder().decode([RemoteMac].self, from: try! enc.encode(savedList))
check("links survive, incomplete ones are not kept", again[0].links.count == 1 && again[0].links[0] == savedList[0].links[0])
savedList[0].links = (1...10).map { link("http://{host}:\($0)", "L\($0)") }
check("at most eight are kept", (try! JSONDecoder().decode([RemoteMac].self, from: try! enc.encode(savedList)))[0].links.count == 8)
check("links without an id still load", (try! JSONDecoder().decode([RemoteMac].self, from: Data("[{\"host\":\"h\",\"links\":[{\"name\":\"Web\",\"address\":\"h\"}]}]".utf8)))[0].links.count == 1)

// diagnosis
typealias F = Diagnosis.Facts
let nowD = Date(timeIntervalSince1970: 1_800_000_000)
func values(_ f: F) -> [String] { Diagnosis.lines(f, now: nowD).map { "\($0.label): \($0.value)" } }
func says(_ f: F) -> String? { Diagnosis.conclusion(f)?.text }
let allOn: Set<UInt16> = [Probe.vnc, Probe.ssh, Probe.smb]
var f = F(name: "Studio"); f.online = true; f.services = allOn; f.wake = .ready; f.tailscale = .connected
check("diagnosis: everything works, nothing shown", !Diagnosis.applies(f) && Diagnosis.conclusion(f) == nil)
f = F(name: "Studio"); f.online = false
check("diagnosis: offline is shown", Diagnosis.applies(f))
f = F(name: "Studio"); f.online = nil
check("diagnosis: not shown while still checking", !Diagnosis.applies(f))
f = F(name: "Mac mini"); f.online = true; f.routedLocally = true; f.services = [Probe.ssh]; f.wake = .ready
f.tailscale = .offline(nowD.addingTimeInterval(-7200)); f.local = .answering("Mac-mini.local")
check("diagnosis: the four lines", values(f) == ["Tailscale: offline, last seen 2 hours ago", "Local network: answering at Mac-mini.local",
      "Services: Screen Sharing off · SSH on · File Sharing off", "Wake: ready"])
check("diagnosis: restarted and not logged in", says(f) == "Tailscale is not running on it. It may have restarted and be waiting for someone to log in.")
f = F(name: "NAS"); f.online = false
check("diagnosis: plain address has no Tailscale line, Nearby off no local line, offline no services line", values(f) == ["Wake: no hardware address known"])
f.tailscale = .offline(nil); check("diagnosis: offline without a time", values(f)[0] == "Tailscale: offline")
f.tailscale = .notListed; check("diagnosis: removed from the tailnet", values(f)[0] == "Tailscale: not on your tailnet")
f.tailscale = .notRunningHere; check("diagnosis: Tailscale stopped here", values(f)[0] == "Tailscale: not running on this Mac")
check("diagnosis: Tailscale stopped here, conclusion and button", says(f) == "Tailscale is not running on this Mac." && Diagnosis.conclusion(f)?.action == .openTailscale)
f.tailscale = .signedOutHere
check("diagnosis: signed out here", values(f)[0] == "Tailscale: signed out on this Mac" && says(f) == "Tailscale is signed out on this Mac." && Diagnosis.conclusion(f)?.action == .openTailscale)
f.tailscale = .connected; check("diagnosis: connected", values(f)[0] == "Tailscale: connected")
f = F(name: "Studio"); f.online = false; f.local = .asleep; f.wake = .ready
check("diagnosis: asleep line and conclusion", values(f)[0] == "Local network: asleep, another device is answering for it" && says(f) == "It is asleep. Connecting wakes it.")
f.local = .notFound; check("diagnosis: not found locally", values(f)[0] == "Local network: not found")
check("diagnosis: offline and can be woken", says(f) == "It is off, asleep or on another network. Connecting tries to wake it.")
f.local = .silent; check("diagnosis: found, not answering", values(f)[0] == "Local network: found, not answering")
f.wake = .through(["Mac mini"]); check("diagnosis: away with a helper", values(f).last == "Wake: ready, through Mac mini" && says(f) == "It is off, asleep or on another network. Connecting tries to wake it.")
f.wake = .noHelper; check("diagnosis: away without a helper", values(f).last == "Wake: no computer at home can pass it on" && says(f) == "It is off, asleep or on another network. No computer at home can pass on the wake-up packet.")
f.wake = .unknown; check("diagnosis: offline and cannot be woken", says(f) == "It is off, asleep or on another network. Hop cannot wake it without its hardware address.")
f = F(name: "Desk", platform: .windows); f.online = true; f.services = [Probe.rdp]; f.wake = .ready
check("diagnosis: Windows services", values(f)[0] == "Services: Remote Desktop on · SSH off · File Sharing off")
check("diagnosis: two services off, not a Mac", says(f) == "SSH and File Sharing appear to be off.")
f = F(name: "Studio"); f.online = true; f.services = [Probe.ssh, Probe.smb]; f.wake = .ready
check("diagnosis: Screen Sharing is off", says(f) == "Screen Sharing appears to be off. Turn it on in System Settings › General › Sharing on that Mac.")
f.services = []; check("diagnosis: three off on a Mac", says(f) == "Screen Sharing, SSH and File Sharing appear to be off. Turn them on in System Settings › General › Sharing on that Mac.")
f = F(name: "Studio"); f.online = false; f.wakeFailed = true; f.wake = .ready
check("diagnosis: did not wake", says(f) == "The wake-up packet was sent and it did not answer. It may be powered off, on Wi-Fi only, or have Wake for network access turned off.")
f.wakeHelper = "Mac mini"; check("diagnosis: did not wake through a helper", says(f)!.hasPrefix("The wake-up packet was sent through Mac mini and it did not answer."))
// the order when several apply
f = F(name: "Studio"); f.online = false; f.hasNetwork = false; f.tailscale = .notRunningHere; f.local = .asleep; f.wakeFailed = true
check("diagnosis order: no network first", says(f) == "This Mac is not connected to a network.")
f.hasNetwork = true; check("diagnosis order: then Tailscale on this Mac", says(f) == "Tailscale is not running on this Mac.")
f.tailscale = .offline(nil); check("diagnosis order: then asleep", says(f) == "It is asleep. Connecting wakes it.")
f.local = .notFound; check("diagnosis order: then a failed wake", says(f)!.hasPrefix("The wake-up packet was sent"))
f = F(name: "Mac mini"); f.online = true; f.routedLocally = true; f.tailscale = .offline(nil); f.services = [Probe.ssh]
check("diagnosis order: local only before a service that is off", says(f)!.hasPrefix("Tailscale is not running on it.") && values(f).contains { $0.contains("Screen Sharing off") })
f.tailscale = .notRunningHere
check("diagnosis: Tailscale off here does not explain a computer that answers", says(f) == "Its saved address does not answer. Hop is reaching it on the local network instead.")
f = F(name: "Studio"); f.online = true; f.services = allOn; f.sleepFailed = .signIn
check("diagnosis: sleep could not sign in", says(f) == "Hop could not sign in to Studio over SSH without a question. Sleep needs SSH that works without a password.")
f.sleepFailed = .refused; check("diagnosis: sleep refused", says(f) == "Studio did not accept the request to sleep. Its account may not be allowed to put it to sleep.")
f = F(name: "Studio"); f.online = false; f.sleptOnRequest = true; f.wake = .ready; f.local = .asleep
check("diagnosis: put to sleep from Hop", says(f) == "You put it to sleep from Hop. Connecting wakes it.")
f.wake = .unknown; check("diagnosis: put to sleep and cannot be woken", says(f) == "You put it to sleep from Hop. Hop cannot wake it from here.")

// sleep
check("sleep: Mac command", RemoteSleep.command(for: .mac)! == ["echo", "hop-sleep", "&&", "/usr/bin/pmset", "sleepnow"])
check("sleep: Linux command", RemoteSleep.command(for: .linux)! == ["echo", "hop-sleep", "&&", "systemctl", "suspend"])
check("sleep: none for Windows", RemoteSleep.command(for: .windows) == nil)
var sleeper = row("10.0.0.2", user: "x", port: 2222, alias: "nas")
check("sleep: alias row", RemoteSleep.arguments(sleeper, configured: cfg)! == Relay.options + ["nas"] + RemoteSleep.command(for: .mac)!)
sleeper.sshAlias = ""; sleeper.platform = .linux
check("sleep: user and port", RemoteSleep.arguments(sleeper, configured: cfg)! == Relay.options + ["-p", "2222", "x@10.0.0.2"] + RemoteSleep.command(for: .linux)!)
sleeper.platform = .windows; check("sleep: no arguments for Windows", RemoteSleep.arguments(sleeper, configured: cfg) == nil)
sleeper.platform = .mac; sleeper.name = "; rm -rf ~"; sleeper.mac = "$(x)"
check("sleep: only the destination comes from the row", RemoteSleep.arguments(sleeper, configured: cfg)!.allSatisfy { !$0.contains("rm") && !$0.contains("$") })
check("sleep: offered", RemoteSleep.offered(platform: .mac, online: true, ssh: true, busy: false) && RemoteSleep.offered(platform: .linux, online: true, ssh: true, busy: false))
check("sleep: not offered", !RemoteSleep.offered(platform: .windows, online: true, ssh: true, busy: false) && !RemoteSleep.offered(platform: .mac, online: false, ssh: true, busy: false)
      && !RemoteSleep.offered(platform: .mac, online: true, ssh: false, busy: false) && !RemoteSleep.offered(platform: .mac, online: true, ssh: true, busy: true))
check("sleep: asks first only when it could not be woken", RemoteSleep.needsConfirmation(.unknown) && RemoteSleep.needsConfirmation(.noHelper)
      && !RemoteSleep.needsConfirmation(.ready) && !RemoteSleep.needsConfirmation(.through(["a"])))
check("sleep: request taken", RemoteSleep.failure(signedIn: true, status: 0, timedOut: false) == nil)
check("sleep: connection lost as it went down", RemoteSleep.failure(signedIn: true, status: 255, timedOut: false) == nil && RemoteSleep.failure(signedIn: true, status: 15, timedOut: true) == nil)
check("sleep: the computer refused", RemoteSleep.failure(signedIn: true, status: 1, timedOut: false) == .refused)
check("sleep: no sign-in", RemoteSleep.failure(signedIn: false, status: 255, timedOut: false) == .signIn && RemoteSleep.failure(signedIn: false, status: 0, timedOut: false) == .signIn)

// knocking on local addresses
let k0 = Date(timeIntervalSince1970: 1_800_000_000)
check("knock: never knocked", LocalNet.knockDue(last: nil, now: k0, looking: false))
check("knock: not again within five minutes", !LocalNet.knockDue(last: k0, now: k0.addingTimeInterval(30), looking: false) && !LocalNet.knockDue(last: k0, now: k0.addingTimeInterval(299), looking: false))
check("knock: again after five minutes", LocalNet.knockDue(last: k0, now: k0.addingTimeInterval(300), looking: false))
check("knock: at once while the user is looking", LocalNet.knockDue(last: k0, now: k0.addingTimeInterval(1), looking: true))

// local addresses worth asking about
check("may be local", LocalNet.mayBeLocal("Studio.local") && LocalNet.mayBeLocal(" 192.168.1.20 ") && !LocalNet.mayBeLocal("studio.t.ts.net") && !LocalNet.mayBeLocal("studio"))


// the helper script
func runScript(_ words: [String]) -> Int32 {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-s", "--"] + words
    p.standardInput = pipe; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    pipe.fileHandleForWriting.write(Data(Relay.script.utf8)); try? pipe.fileHandleForWriting.close()
    p.waitUntilExit()
    return p.terminationStatus
}
check("script: no hardware address exits 2", runScript([]) == 2 && runScript(["192.168.1.255"]) == 2)
if live { check("script: sends for an invented address", runScript(["aabbcc000099"]) == 0) }

// END
if CommandLine.arguments.contains("--script") { print(Relay.script); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--relay") {
    let dest = Array(CommandLine.arguments[(i + 1)...])
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t = Date()
        let ok = await Relay.send(through: dest, addresses: [[0xaa, 0xbb, 0xcc, 0, 0, 0x99]], broadcast: "192.168.1.255")
        print("relay through", dest, "sent:", ok, String(format: "in %.1f s", Date().timeIntervalSince(t)))
        sem.signal()
    }
    sem.wait(); exit(0)
}

print(fails == 0 ? "ALL OK, \(count) checks" : "\(fails) of \(count) FAILED")
exit(fails == 0 ? 0 : 1)
