import SwiftUI
import AppKit
import Combine

let envPrefix = "export PATH=/opt/local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
let airportBin = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
let wifiPrefix = "Current Wi-Fi Network: "
let svc = "Wi-Fi"

@discardableResult
func sh(_ cmd: String) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", envPrefix + cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("\(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8) ?? ""
    return (s.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
}

/// Runs an executable directly (no shell), so passwords/SSIDs need no quoting.
@discardableResult
func runExec(_ path: String, _ args: [String]) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("\(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8) ?? ""
    return (s.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
}

func shQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a shell command as root through the standard macOS admin password dialog.
/// Returns an error message, "" if the user cancelled, or nil on success.
func shAdmin(_ cmd: String) -> String? {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    guard let script = NSAppleScript(source: "do shell script \"\(envPrefix)\(esc)\" with administrator privileges") else {
        return "Could not build script"
    }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    if let err = err {
        let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
        return msg.lowercased().contains("cancel") ? "" : msg
    }
    return nil
}

struct WifiNet: Identifiable, Hashable {
    let id = UUID()
    let ssid: String
    let rssi: Int
    let channel: String
    let security: String
    var secured: Bool { !security.isEmpty && !security.contains("NONE") }
}

struct Diag {
    var ran = false
    var assoc = false
    var ip = ""
    var hasIP = false
    var gateway = ""
    var gatewayOK: Bool? = nil
    var internetOK: Bool? = nil
    var dnsOK: Bool? = nil
    var publicDNSOK: Bool? = nil
    var verdict = "Press “Run diagnosis”."
    var healthy = false
}

struct InfoRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

struct DNSResult: Identifiable {
    let id = UUID()
    let name: String
    let ms: String
}

let dnsPresets: [(name: String, servers: [String])] = [
    ("Cloudflare", ["1.1.1.1", "1.0.0.1"]),
    ("Google", ["8.8.8.8", "8.8.4.4"]),
    ("Quad9", ["9.9.9.9", "149.112.112.112"]),
    ("OpenDNS", ["208.67.222.222", "208.67.220.220"]),
]

final class Model: ObservableObject {
    // connection
    @Published var wifiOn = false
    @Published var wifiSSID = ""
    @Published var wifiIP = ""
    @Published var wifiRSSI = ""
    @Published var wifiNets: [WifiNet] = []
    @Published var wifiSaved: [String] = []
    @Published var wifiScanning = false
    @Published var wifiNote = ""

    // fix / diagnose
    @Published var diag = Diag()
    @Published var diagRunning = false
    @Published var working = false
    @Published var opNote = ""
    @Published var resetDNSOnFix = false
    @Published var autoRecover = false
    @Published var recoverNote = ""

    // dns
    @Published var dnsConfigured: [String] = []
    @Published var dnsInUse: [String] = []
    @Published var dnsBench: [DNSResult] = []
    @Published var dnsBusy = false
    @Published var customDNS = ""

    // info
    @Published var info: [InfoRow] = []
    @Published var publicIP = ""

    private let q = DispatchQueue(label: "poll")
    private var timer: Timer?
    private var noIPTicks = 0
    private var lastRecover = Date.distantPast

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: Polling

    func refresh() {
        q.async {
            let wOn = sh("networksetup -getairportpower en0").out.hasSuffix("On")
            let wNet = sh("networksetup -getairportnetwork en0").out
            let wSSID = wNet.hasPrefix(wifiPrefix) ? String(wNet.dropFirst(wifiPrefix.count)) : ""
            var wIP = ""
            var wRSSI = ""
            if !wSSID.isEmpty {
                let ipOut = sh("ipconfig getifaddr en0")
                wIP = ipOut.code == 0 ? ipOut.out : ""
                wRSSI = sh("\(airportBin) -I | awk '/agrCtlRSSI/{print $2}'").out
            }
            let wSaved = runExec("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", "en0"]).out
                .split(separator: "\n").dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            DispatchQueue.main.async {
                let wasOn = self.wifiOn
                self.wifiOn = wOn
                self.wifiSSID = wSSID
                self.wifiIP = wIP
                self.wifiRSSI = wRSSI
                self.wifiSaved = wSaved
                if wOn && !wasOn { self.scanWifi() }
                self.watchdog()
            }
        }
    }

    /// Optional: if associated but with no usable IP for ~20s, cycle Wi-Fi power (needs no admin rights).
    private func watchdog() {
        let bad = !wifiSSID.isEmpty && (wifiIP.isEmpty || wifiIP.hasPrefix("169.254"))
        noIPTicks = bad ? noIPTicks + 1 : 0
        guard autoRecover, bad, noIPTicks >= 10, !working,
              Date().timeIntervalSince(lastRecover) > 90 else { return }
        lastRecover = Date()
        noIPTicks = 0
        recoverNote = "Auto-recover: no IP, restarting Wi-Fi…"
        restartWifi()
    }

    // MARK: Wi-Fi basics

    func setWifi(_ on: Bool) {
        wifiNote = ""
        q.async {
            runExec("/usr/sbin/networksetup", ["-setairportpower", "en0", on ? "on" : "off"])
            DispatchQueue.main.async {
                if !on { self.wifiNets = [] }
                self.refresh()
            }
        }
    }

    func restartWifi() {
        wifiNote = "Restarting Wi-Fi…"
        wifiNets = []
        q.async {
            runExec("/usr/sbin/networksetup", ["-setairportpower", "en0", "off"])
            Thread.sleep(forTimeInterval: 2)
            runExec("/usr/sbin/networksetup", ["-setairportpower", "en0", "on"])
            Thread.sleep(forTimeInterval: 3)
            DispatchQueue.main.async {
                self.wifiNote = ""
                self.refresh()
                self.scanWifi()
            }
        }
    }

    func scanWifi() {
        if wifiScanning { return }
        wifiScanning = true
        q.async {
            let out = sh("\(airportBin) -s").out
            var best: [String: WifiNet] = [:]
            for line in out.split(separator: "\n").dropFirst() {
                let s = String(line)
                if s.count < 40 { continue }
                let ssid = String(s.prefix(33)).trimmingCharacters(in: .whitespaces)
                if ssid.isEmpty { continue }
                var rest = s.dropFirst(33).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                // BSSID RSSI CHANNEL HT CC SECURITY...  (BSSID is blank without location access)
                if let f = rest.first, f.contains(":") { rest.removeFirst() }
                if rest.count < 5 { continue }
                let rssi = Int(rest[0]) ?? -100
                let net = WifiNet(ssid: ssid, rssi: rssi, channel: rest[1], security: rest[4...].joined(separator: " "))
                if let old = best[ssid], old.rssi >= rssi { continue }
                best[ssid] = net
            }
            let nets = best.values.sorted { $0.rssi > $1.rssi }
            DispatchQueue.main.async {
                self.wifiNets = nets
                self.wifiScanning = false
            }
        }
    }

    func joinWifi(_ ssid: String, password: String?) {
        wifiNote = "Joining \(ssid)…"
        q.async {
            var args = ["-setairportnetwork", "en0", ssid]
            if let p = password, !p.isEmpty { args.append(p) }
            let r = runExec("/usr/sbin/networksetup", args)
            DispatchQueue.main.async {
                self.wifiNote = r.out.isEmpty ? "" : r.out
                self.refresh()
            }
        }
    }

    func forget(_ ssid: String) {
        runAdmin("networksetup -removepreferredwirelessnetwork en0 \(shQuote(ssid))", note: "Forgot “\(ssid)”.")
    }

    // MARK: Admin operations

    func runAdmin(_ cmd: String, note: String, after: (() -> Void)? = nil) {
        working = true
        opNote = ""
        q.async {
            let err = shAdmin(cmd)
            DispatchQueue.main.async {
                self.working = false
                if let err = err {
                    self.opNote = err.isEmpty ? "Cancelled." : "Failed: \(err)"
                } else {
                    self.opNote = note
                }
                self.refresh()
                self.loadDNS()
                after?()
            }
        }
    }

    func flushDNS() {
        runAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder", note: "DNS cache flushed.") { self.runDiag() }
    }

    func renewDHCP() {
        runAdmin("networksetup -setdhcp \(svc); ipconfig set en0 DHCP", note: "DHCP lease renewed.") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.runDiag() }
        }
    }

    func fixAll() {
        var cmd = "dscacheutil -flushcache; killall -HUP mDNSResponder; networksetup -setdhcp \(svc); "
        if resetDNSOnFix { cmd += "networksetup -setdnsservers \(svc) Empty; " }
        cmd += "networksetup -setairportpower en0 off; sleep 2; networksetup -setairportpower en0 on; sleep 6; "
        cmd += "ipconfig set en0 DHCP; sleep 3; dscacheutil -flushcache; killall -HUP mDNSResponder"
        runAdmin(cmd, note: "Repair finished. Re-checking…") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.runDiag() }
        }
    }

    // MARK: Diagnosis

    func runDiag() {
        if diagRunning { return }
        diagRunning = true
        q.async {
            var d = Diag()
            d.ran = true
            let ssid = sh("networksetup -getairportnetwork en0").out
            d.assoc = ssid.hasPrefix(wifiPrefix)
            let ipOut = sh("ipconfig getifaddr en0")
            d.ip = ipOut.code == 0 ? ipOut.out : ""
            d.hasIP = !d.ip.isEmpty && !d.ip.hasPrefix("169.254")
            if d.assoc && d.hasIP {
                d.gateway = sh("networksetup -getinfo \(svc) | awk '/^Router:/{print $2}'").out
                if !d.gateway.isEmpty && d.gateway != "none" {
                    d.gatewayOK = sh("ping -c 2 -t 3 -b en0 \(d.gateway)").code == 0
                }
                d.internetOK = sh("ping -c 2 -t 3 -b en0 1.1.1.1").code == 0
                d.dnsOK = !sh("dig +time=3 +tries=1 +short apple.com | head -1").out.isEmpty
                d.publicDNSOK = !sh("dig @1.1.1.1 +time=3 +tries=1 +short apple.com | head -1").out.isEmpty
            }
            if !d.assoc {
                d.verdict = "Not connected to a Wi-Fi network."
            } else if !d.hasIP {
                d.verdict = "Connected but no valid IP address (DHCP failed). Press “Fix connection”."
            } else if d.internetOK == false && d.gatewayOK == false {
                d.verdict = "Router isn't responding. Move closer, or restart the router."
            } else if d.internetOK == false {
                d.verdict = "Router answers but there's no internet beyond it. Check the ISP / router uplink."
            } else if d.dnsOK == false && d.publicDNSOK == true {
                d.verdict = "Internet works but your DNS server is failing. Flush DNS or switch DNS (DNS tab)."
            } else if d.dnsOK == false {
                d.verdict = "DNS lookups are failing. Flush DNS, then try switching DNS."
            } else {
                d.verdict = "Everything is working."
                d.healthy = true
            }
            DispatchQueue.main.async {
                self.diag = d
                self.diagRunning = false
            }
        }
    }

    // MARK: DNS

    func loadDNS() {
        q.async {
            let c = sh("networksetup -getdnsservers \(svc)").out
            let configured = c.contains("any DNS") ? [] : c.split(separator: "\n").map(String.init)
            let used = sh("scutil --dns | awk '/nameserver\\[/{print $3}' | sort -u | head -4").out
                .split(separator: "\n").map(String.init)
            DispatchQueue.main.async {
                self.dnsConfigured = configured
                self.dnsInUse = used
            }
        }
    }

    func setDNS(_ servers: [String]) {
        let list = servers.isEmpty ? "Empty" : servers.joined(separator: " ")
        runAdmin("networksetup -setdnsservers \(svc) \(list); dscacheutil -flushcache; killall -HUP mDNSResponder",
                 note: servers.isEmpty ? "DNS set to automatic." : "DNS set to \(servers.joined(separator: ", ")).")
    }

    func benchDNS() {
        if dnsBusy { return }
        dnsBusy = true
        dnsBench = []
        q.async {
            var results: [DNSResult] = []
            var targets: [(String, String)] = [("System default", "")]
            for p in dnsPresets { targets.append((p.name, "@" + p.servers[0])) }
            for (name, at) in targets {
                let ms = sh("dig \(at) apple.com +time=2 +tries=1 | awk '/Query time/{print $4}'").out
                results.append(DNSResult(name: name, ms: ms.isEmpty ? "fail" : "\(ms) ms"))
                DispatchQueue.main.async { self.dnsBench = results }
            }
            DispatchQueue.main.async { self.dnsBusy = false }
        }
    }

    // MARK: Info

    func loadInfo() {
        q.async {
            var d: [String: String] = [:]
            for l in sh("\(airportBin) -I").out.split(separator: "\n") {
                let parts = l.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    d[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let gi = sh("networksetup -getinfo \(svc)").out
            func field(_ k: String) -> String {
                for l in gi.split(separator: "\n") where l.hasPrefix(k) {
                    return l.dropFirst(k.count).trimmingCharacters(in: .whitespaces)
                }
                return "—"
            }
            let rssi = Int(d["agrCtlRSSI"] ?? "") ?? 0
            let noise = Int(d["agrCtlNoise"] ?? "") ?? 0
            var rows: [InfoRow] = []
            rows.append(InfoRow(key: "Network", value: d["SSID"] ?? "—"))
            rows.append(InfoRow(key: "Channel", value: d["channel"] ?? "—"))
            rows.append(InfoRow(key: "Signal", value: rssi == 0 ? "—" : "\(rssi) dBm"))
            rows.append(InfoRow(key: "Noise", value: noise == 0 ? "—" : "\(noise) dBm"))
            rows.append(InfoRow(key: "SNR", value: rssi == 0 ? "—" : "\(rssi - noise) dB"))
            rows.append(InfoRow(key: "Link speed", value: (d["lastTxRate"] ?? "0") == "0" ? "—" : "\(d["lastTxRate"]!) Mbps"))
            rows.append(InfoRow(key: "Security", value: d["link auth"] ?? "—"))
            rows.append(InfoRow(key: "IP address", value: field("IP address:")))
            rows.append(InfoRow(key: "Subnet mask", value: field("Subnet mask:")))
            rows.append(InfoRow(key: "Router", value: field("Router:")))
            rows.append(InfoRow(key: "MAC address", value: sh("ifconfig en0 | awk '/ether/{print $2}'").out))
            DispatchQueue.main.async { self.info = rows }
        }
    }

    func fetchPublicIP() {
        publicIP = "…"
        q.async {
            let r = sh("curl -s -m 6 https://api.ipify.org")
            DispatchQueue.main.async { self.publicIP = r.code == 0 && !r.out.isEmpty ? r.out : "unavailable" }
        }
    }
}

// MARK: - Shared views

struct Light: View {
    let state: Bool?
    var body: some View {
        Circle()
            .fill(state == nil ? Color.gray.opacity(0.5) : (state! ? Color.green : Color.red))
            .frame(width: 10, height: 10)
    }
}

struct CheckRow: View {
    let label: String
    let state: Bool?
    let detail: String
    var body: some View {
        HStack {
            Light(state: state)
            Text(label)
            Spacer()
            Text(detail).foregroundColor(.secondary).font(.system(size: 12, design: .monospaced))
        }
    }
}

struct JoinSheet: View {
    let net: WifiNet
    let onJoin: (String?) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join “\(net.ssid)”").font(.headline)
            if net.secured {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if password.count >= 8 { onJoin(password) } }
            } else {
                Text("Open network, no password.").foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Join") { onJoin(net.secured ? password : nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(net.secured && password.count < 8)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - Networks tab

struct NetworksTab: View {
    @ObservedObject var m: Model
    @State private var joining: WifiNet?
    private let autoScan = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var inRangeSaved: Bool { m.wifiNets.contains { m.wifiSaved.contains($0.ssid) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Text("Wi-Fi").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Wi-Fi on", isOn: Binding(get: { m.wifiOn }, set: { m.setWifi($0) }))
                    if !m.wifiSSID.isEmpty {
                        Text("\(m.wifiRSSI) dBm  ·  \(m.wifiIP.isEmpty ? "no IP" : m.wifiIP)")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                    HStack {
                        Button("Scan") { m.scanWifi() }.disabled(!m.wifiOn || m.wifiScanning)
                        Button("Restart Wi-Fi") { m.restartWifi() }
                        if m.wifiScanning { ProgressView().controlSize(.small) }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if m.wifiOn && m.wifiSSID.isEmpty && !m.wifiNets.isEmpty && !inRangeSaved {
                Text("None of your saved networks are in range. Pick one below.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            if !m.wifiNote.isEmpty {
                Text(m.wifiNote).font(.footnote).foregroundColor(.secondary)
            }

            if !m.wifiOn {
                Spacer()
                Text("Switch Wi-Fi on to see networks.").foregroundColor(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                nearby
                saved
            }
        }
        .padding(16)
        .onReceive(autoScan) { _ in if m.wifiOn { m.scanWifi() } }
        .onAppear { if m.wifiOn { m.scanWifi() } }
        .sheet(item: $joining) { net in
            JoinSheet(net: net, onJoin: { pw in
                m.joinWifi(net.ssid, password: pw)
                joining = nil
            }, onCancel: { joining = nil })
        }
    }

    var nearby: some View {
        GroupBox(label: Text("Networks nearby").font(.subheadline)) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(m.wifiNets) { n in
                        Button { joining = n } label: {
                            HStack {
                                Image(systemName: n.secured ? "lock.fill" : "lock.open")
                                    .frame(width: 18).foregroundColor(.secondary)
                                Text(n.ssid)
                                if m.wifiSaved.contains(n.ssid) {
                                    Text("saved").font(.caption2).foregroundColor(.accentColor)
                                }
                                Spacer()
                                Text("\(n.rssi) dBm").font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 4)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    if m.wifiNets.isEmpty && !m.wifiScanning {
                        Text("No networks found. Press Scan.").foregroundColor(.secondary).padding()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var saved: some View {
        GroupBox(label: Text("Saved networks (\(m.wifiSaved.count))").font(.subheadline)) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(m.wifiSaved, id: \.self) { s in
                        HStack {
                            Text(s)
                            Spacer()
                            Button("Connect") { m.joinWifi(s, password: nil) }.controlSize(.small)
                            Button("Forget") { m.forget(s) }.controlSize(.small)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 90)
        }
    }
}

// MARK: - Fix tab

struct FixTab: View {
    @ObservedObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Text("Diagnosis").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        CheckRow(label: "Connected to Wi-Fi", state: m.diag.ran ? m.diag.assoc : nil,
                                 detail: m.diag.assoc ? m.wifiSSID : "—")
                        CheckRow(label: "Valid IP address", state: m.diag.ran ? m.diag.hasIP : nil,
                                 detail: m.diag.ip.isEmpty ? "none" : m.diag.ip)
                        CheckRow(label: "Router reachable", state: m.diag.gatewayOK,
                                 detail: m.diag.gateway.isEmpty ? "—" : m.diag.gateway)
                        CheckRow(label: "Internet (by IP)", state: m.diag.internetOK, detail: "1.1.1.1")
                        CheckRow(label: "DNS resolving", state: m.diag.dnsOK, detail: "system")
                        CheckRow(label: "Public DNS resolving", state: m.diag.publicDNSOK, detail: "1.1.1.1")
                        Divider()
                        Text(m.diag.verdict)
                            .font(.callout)
                            .foregroundColor(m.diag.healthy ? .green : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Run diagnosis") { m.runDiag() }.disabled(m.diagRunning)
                            if m.diagRunning { ProgressView().controlSize(.small) }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Repair").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Fix connection") { m.fixAll() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(m.working)
                        Text("Flushes DNS, resets to DHCP, restarts Wi-Fi and requests a fresh IP. Asks for your password once.")
                            .font(.footnote).foregroundColor(.secondary)
                        Toggle("Also reset DNS servers to automatic", isOn: $m.resetDNSOnFix)
                        Divider()
                        HStack {
                            Button("Flush DNS") { m.flushDNS() }.disabled(m.working)
                            Button("Renew IP (DHCP)") { m.renewDHCP() }.disabled(m.working)
                            Button("Restart Wi-Fi") { m.restartWifi() }.disabled(m.working)
                        }
                        Divider()
                        Toggle("Auto-recover: restart Wi-Fi if connected with no IP", isOn: $m.autoRecover)
                        if !m.recoverNote.isEmpty {
                            Text(m.recoverNote).font(.footnote).foregroundColor(.secondary)
                        }
                        if m.working {
                            HStack { ProgressView().controlSize(.small); Text("Working…").foregroundColor(.secondary) }
                        }
                        if !m.opNote.isEmpty {
                            Text(m.opNote).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .onAppear { m.runDiag() }
    }
}

// MARK: - DNS tab

struct DNSTab: View {
    @ObservedObject var m: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Text("Current DNS").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Set manually")
                            Spacer()
                            Text(m.dnsConfigured.isEmpty ? "Automatic (from router)" : m.dnsConfigured.joined(separator: ", "))
                                .foregroundColor(.secondary).font(.system(size: 12, design: .monospaced))
                        }
                        HStack {
                            Text("In use")
                            Spacer()
                            Text(m.dnsInUse.isEmpty ? "—" : m.dnsInUse.joined(separator: ", "))
                                .foregroundColor(.secondary).font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Switch DNS").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dnsPresets, id: \.name) { p in
                            HStack {
                                Text(p.name)
                                Text(p.servers.joined(separator: ", "))
                                    .foregroundColor(.secondary).font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Button("Use") { m.setDNS(p.servers) }.disabled(m.working)
                            }
                        }
                        HStack {
                            Text("Automatic")
                            Spacer()
                            Button("Use") { m.setDNS([]) }.disabled(m.working)
                        }
                        Divider()
                        HStack {
                            TextField("Custom, e.g. 9.9.9.9 8.8.8.8", text: $m.customDNS)
                                .textFieldStyle(.roundedBorder)
                            Button("Use") {
                                let list = m.customDNS.split(whereSeparator: { " ,".contains($0) }).map(String.init)
                                if !list.isEmpty { m.setDNS(list) }
                            }
                            .disabled(m.working || m.customDNS.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if !m.opNote.isEmpty {
                            Text(m.opNote).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Text("Speed test").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.dnsBench) { r in
                            HStack {
                                Text(r.name)
                                Spacer()
                                Text(r.ms).font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(r.ms == "fail" ? .red : .secondary)
                            }
                        }
                        HStack {
                            Button("Benchmark resolvers") { m.benchDNS() }.disabled(m.dnsBusy)
                            if m.dnsBusy { ProgressView().controlSize(.small) }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .onAppear { m.loadDNS() }
    }
}

// MARK: - Info tab

struct InfoTab: View {
    @ObservedObject var m: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox(label: Text("Connection details").font(.headline)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.info) { r in
                            HStack {
                                Text(r.key)
                                Spacer()
                                Text(r.value).foregroundColor(.secondary)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if m.info.isEmpty { Text("—").foregroundColor(.secondary) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(label: Text("Public IP").font(.headline)) {
                    HStack {
                        Text(m.publicIP.isEmpty ? "Not checked" : m.publicIP)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Check") { m.fetchPublicIP() }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("“Check” contacts api.ipify.org to read your public IP.")
                    .font(.footnote).foregroundColor(.secondary)
                Button("Refresh") { m.loadInfo() }
            }
            .padding(16)
        }
        .onAppear { m.loadInfo() }
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Light(state: m.wifiSSID.isEmpty ? (m.wifiOn ? nil : false) : true)
                Text(m.wifiSSID.isEmpty ? (m.wifiOn ? "Not connected" : "Wi-Fi is off") : m.wifiSSID)
                    .font(.headline)
                Spacer()
                if !m.wifiSSID.isEmpty {
                    Text(m.wifiIP.isEmpty ? "no IP" : m.wifiIP)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(m.wifiIP.isEmpty || m.wifiIP.hasPrefix("169.254") ? .red : .secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            TabView {
                NetworksTab(m: m).tabItem { Label("Networks", systemImage: "wifi") }
                FixTab(m: m).tabItem { Label("Fix", systemImage: "wrench.and.screwdriver") }
                DNSTab(m: m).tabItem { Label("DNS", systemImage: "globe") }
                InfoTab(m: m).tabItem { Label("Info", systemImage: "info.circle") }
            }
        }
        .frame(width: 480, height: 640)
    }
}

struct MenuView: View {
    @ObservedObject var m: Model
    let openWindow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Light(state: m.wifiSSID.isEmpty ? (m.wifiOn ? nil : false) : true)
                Text(m.wifiSSID.isEmpty ? (m.wifiOn ? "Not connected" : "Wi-Fi is off") : m.wifiSSID)
                    .font(.headline)
                Spacer()
                if !m.wifiSSID.isEmpty {
                    Text(m.wifiIP.isEmpty ? "no IP" : m.wifiIP)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(m.wifiIP.isEmpty || m.wifiIP.hasPrefix("169.254") ? .red : .secondary)
                }
            }
            Toggle("Wi-Fi on", isOn: Binding(get: { m.wifiOn }, set: { m.setWifi($0) }))
            Divider()
            Button("Fix connection") { m.fixAll() }.disabled(m.working)
            HStack {
                Button("Flush DNS") { m.flushDNS() }.disabled(m.working)
                Button("Renew IP") { m.renewDHCP() }.disabled(m.working)
                Button("Restart") { m.restartWifi() }.disabled(m.working)
            }
            Menu("Switch DNS") {
                ForEach(dnsPresets, id: \.name) { p in
                    Button(p.name) { m.setDNS(p.servers) }
                }
                Button("Automatic") { m.setDNS([]) }
            }
            .disabled(m.working)
            if m.working { HStack { ProgressView().controlSize(.small); Text("Working…").foregroundColor(.secondary) } }
            if !m.opNote.isEmpty { Text(m.opNote).font(.footnote).foregroundColor(.secondary) }
            Divider()
            HStack {
                Button("Open window…") { openWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow?
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuView(m: model, openWindow: { [weak self] in self?.showWindow() }))
        updateIcon()
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let host = NSHostingView(rootView: ContentView(m: model))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Wi-Fi Manager"
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func symbol(_ names: [String]) -> NSImage? {
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: nil) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    func setDot(_ color: NSColor?) {
        guard let b = statusItem.button else { return }
        if let c = color {
            b.attributedTitle = NSAttributedString(string: " ●",
                attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 9)])
        } else {
            b.attributedTitle = NSAttributedString(string: "")
        }
    }

    func updateIcon() {
        let hasIP = !model.wifiIP.isEmpty && !model.wifiIP.hasPrefix("169.254")
        if !model.wifiOn {
            statusItem.button?.image = symbol(["wifi.slash"])
            setDot(nil)
        } else if model.wifiSSID.isEmpty {
            statusItem.button?.image = symbol(["wifi.circle", "wifi"])
            setDot(NSColor.systemOrange)
        } else if !hasIP {
            statusItem.button?.image = symbol(["wifi.exclamationmark", "wifi"])
            setDot(NSColor.systemRed)
        } else {
            statusItem.button?.image = symbol(["wifi.circle.fill", "wifi.circle", "wifi"])
            setDot(NSColor.systemGreen)
        }
    }
}

@main
struct WifiManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
