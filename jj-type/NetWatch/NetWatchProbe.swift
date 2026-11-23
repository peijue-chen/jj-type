//
//  NetWatchProbe.swift
//  jj-type
//
//  Blocking probes and actions for the network watchdog. Everything here is
//  `nonisolated` on purpose: the service runs these on a detached task so the
//  main thread never waits on ping/curl/networksetup.
//
//  Two rules learned from the real machine:
//  1. A full-tunnel VPN owns the default route, so "is the physical network
//     up?" must be answered by binding to the physical interface, never by a
//     plain `ping 1.1.1.1`.
//  2. `ping <vpn-internal-host>` is useless: the VPN server may drop ICMP.
//     VPN state comes from `scutil --nc status` (with a utun fallback).
//

import Foundation

nonisolated struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
    var trimmedOut: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The three-layer connectivity verdict.
///
/// Modelled as a progression instead of a single boolean because the right
/// action differs per layer, and the old "is the VPN service connected?" check
/// could not tell them apart:
///
///   .noLink       — 物理链路都不通 (no interface, or gateway unreachable).
///                   不要先打 API；直接走「备用网络 + OpenVPN」。
///   .localOnly    — 国内通、国外不通。出国的那条路断了。
///                   直接重启 OpenVPN（关掉再打开），不要切网络。
///   .overseasOK   — 国外链接真的能访问。这才是「VPN 通了」的实证。
///
/// `overseasOK` is deliberately based on a real HTTPS request rather than
/// `scutil`: a VPN may be provided by another client, or the network itself may
/// already be a VPN, in which case no system VPN service exists at all.
nonisolated enum Connectivity: Equatable {
    case noLink(reason: String)
    case localOnly(domestic: String, overseas: String)
    case overseasOK(detail: String)

    var overseasReachable: Bool {
        if case .overseasOK = self { return true }
        return false
    }

    /// True when the machine has any working internet at all.
    var hasInternet: Bool {
        if case .noLink = self { return false }
        return true
    }

    var detail: String {
        switch self {
        case .noLink(let reason): return "no link: \(reason)"
        case .localOnly(let domestic, let overseas):
            return "domestic ok (\(domestic)), overseas failed (\(overseas))"
        case .overseasOK(let detail): return "overseas ok (http \(detail))"
        }
    }
}

nonisolated enum NetWatchProbe {

    // MARK: - Command runner

    /// Runs a command with a hard timeout. Output is small for every command
    /// used here, so reading the pipes after termination cannot deadlock.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
        }

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    // MARK: - Interfaces

    /// Wi-Fi interface from `networksetup -listallhardwareports` (usually en0).
    static func detectWiFiInterface() -> String {
        let result = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var expectingDevice = false
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                expectingDevice = trimmed.contains("Wi-Fi") || trimmed.contains("AirPort")
            } else if expectingDevice, trimmed.hasPrefix("Device:") {
                let device = trimmed.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !device.isEmpty { return device }
            }
        }
        return "en0"
    }

    /// Every `en*` interface that currently has an IPv4 address.
    ///
    /// `ipconfig getifaddr` is NOT enough on its own: it answers from the
    /// DHCP lease cache, so an unplugged Ethernet adapter can keep reporting
    /// an address for a while. That is exactly the failure seen with a USB
    /// adapter — the cable was pulled, but the probe still believed `en7` was
    /// alive (gateway ping then timed out and the watchdog never escalated
    /// because the interface list was never empty). `ifconfig <if>` marks a
    /// dead link, so the interface is also required to be `status: active`.
    static func activeInterfaces() -> [String] {
        let list = run("/sbin/ifconfig", ["-l"]).trimmedOut
        var result: [String] = []
        for name in list.split(separator: " ").map(String.init) where name.hasPrefix("en") {
            let address = run("/usr/sbin/ipconfig", ["getifaddr", name]).trimmedOut
            guard !address.isEmpty else { continue }
            guard linkIsActive(name) else { continue }
            result.append(name)
        }
        return result
    }

    /// True when the interface reports `status: active`. Interfaces that do not
    /// report a status line at all are treated as active so this check can only
    /// ever remove interfaces that are definitely down.
    static func linkIsActive(_ interface: String) -> Bool {
        let result = run("/sbin/ifconfig", [interface])
        guard result.succeeded else { return false }
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("status:") {
                return trimmed.contains("active")
            }
        }
        return true
    }

    static func gateway(for interface: String) -> String? {
        let value = run("/usr/sbin/ipconfig", ["getoption", interface, "router"]).trimmedOut
        return value.isEmpty ? nil : value
    }

    /// The single entry point the watchdog uses.
    ///
    /// Order matters and is deliberate — it is cheaper and more truthful to
    /// ask from the bottom up:
    ///
    ///   1. Is there a physical link at all? (interface + gateway ping)
    ///      No → `.noLink`. Never fire an HTTP request on a dead link.
    ///   2. Can we reach the overseas URL? → `.overseasOK`. Nothing to fix.
    ///   3. Only then, is the domestic internet alive?
    ///      Yes → `.localOnly` (the route abroad is broken → restart OpenVPN)
    ///      No  → `.noLink`   (everything is down → switch network first)
    ///
    /// Asking overseas AFTER the link check also prevents a 5-8 s hang on every
    /// tick when the cable is unplugged.
    static func probeConnectivity(overseasURL: String, domesticURL: String) -> Connectivity {
        // Layer 1: physical link. A full-tunnel VPN owns the default route, so
        // the gateway ping is bound to the interface.
        let interfaces = activeInterfaces()
        if interfaces.isEmpty {
            return .noLink(reason: "no active interface")
        }
        var linkDetail = "no reachable interface"
        var linkedInterface: String?
        for interface in interfaces {
            guard let gateway = gateway(for: interface) else { continue }
            let ping = run("/sbin/ping", ["-c", "1", "-t", "2", "-b", interface, gateway], timeout: 5)
            if ping.succeeded {
                linkedInterface = interface
                linkDetail = "\(interface): gateway \(gateway) ok"
                break
            }
            linkDetail = "\(interface): gateway \(gateway) unreachable"
        }
        // Only used as a nil check: the interface name itself is already in
        // `linkDetail`, so binding it would just produce an unused value.
        guard linkedInterface != nil else {
            return .noLink(reason: linkDetail)
        }

        // Layer 2: the real question — can we actually open an overseas site?
        let overseas = httpProbe(url: overseasURL)
        if overseas.reachable {
            return .overseasOK(detail: overseas.summary)
        }

        // Layer 3: is the domestic internet alive? This is what separates
        // "只有出国的路断了" from "整个网络都不通".
        //
        // The configured domestic URL is not trusted on its own: a single
        // endpoint being down (maintenance, DNS hiccup) must not be reported as
        // a whole-network outage — that would switch the user's Wi-Fi for no
        // reason. A short fallback list decides.
        var domestic = httpProbe(url: domesticURL)
        if !domestic.reachable {
            for fallback in domesticFallbackURLs where fallback != domesticURL {
                let retry = httpProbe(url: fallback)
                if retry.reachable { domestic = retry; break }
            }
        }
        if domestic.reachable {
            return .localOnly(domestic: domestic.summary, overseas: overseas.summary)
        }
        return .noLink(reason: "\(linkDetail); domestic unreachable (\(domestic.summary))")
    }

    /// Endpoints tried when the configured domestic URL does not answer. Kept
    /// small and independent of any single provider.
    private static let domesticFallbackURLs = [
        "https://www.baidu.com/img/flexible/logo/pc/result.png",
        "https://ip.cn/",
        "http://connect.rom.miui.com/generate_204",
    ]

    /// `(reachable, summary)` for one URL. Any HTTP status counts as reachable:
    /// a captive portal or a 302 answers too, and only a transport failure
    /// (DNS / connect / TLS / timeout) means the path is down.
    static func httpProbe(url urlString: String) -> (reachable: Bool, summary: String) {
        let curl = run("/usr/bin/curl",
                       ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                        "--max-time", "8", urlString],
                       timeout: 11)
        if curl.succeeded {
            let code = curl.trimmedOut
            return (true, code.isEmpty ? "no status" : code)
        }
        let err = curl.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, "exit \(curl.exitCode)\(err.isEmpty ? "" : " \(err)")")
    }

    // MARK: - VPN probe

    static func utunHasAddress() -> Bool {
        let result = run("/sbin/ifconfig", [])
        var current = ""
        for line in result.stdout.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                current = line.components(separatedBy: ":").first ?? ""
            } else if current.hasPrefix("utun"), line.contains("inet ") {
                return true
            }
        }
        return false
    }

    // MARK: - Wi-Fi actions

    static func currentWiFiSSID(interface: String) -> String? {
        let result = run("/usr/sbin/networksetup", ["-getairportnetwork", interface])
        let text = result.trimmedOut
        guard let range = text.range(of: "Current Wi-Fi Network:") else { return nil }
        let ssid = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }

    static func wifiPowerOn(interface: String) -> Bool {
        run("/usr/sbin/networksetup", ["-setairportpower", interface, "on"]).succeeded
    }

    static func wifiPowerState(interface: String) -> Bool? {
        let text = run("/usr/sbin/networksetup", ["-getairportpower", interface]).trimmedOut
        if text.hasSuffix(": On") { return true }
        if text.hasSuffix(": Off") { return false }
        return nil
    }

    /// Powers Wi-Fi on, waits for the radio to come up, joins the SSID and
    /// waits for the association to appear.
    ///
    /// Two real-world details make this more than a single command:
    /// 1. `-setairportnetwork` runs immediately after `-setairportpower on` is
    ///    silently dropped — the interface is still off, so the join command
    ///    reports success without ever associating. The radio must be polled
    ///    until it reports On first.
    /// 2. `networksetup` can exit 0 even when the join failed, so the SSID is
    ///    verified by polling instead of trusting the exit code.
    /// `keepPoweredOn` leaves the radio on after a failed join.
    ///
    /// A MANUAL switch restores the original power state (the user's machine is
    /// changed back), but an AUTOMATIC outage response must leave the radio ON:
    /// the whole point is to keep trying the backup network, and constantly
    /// power-cycling the radio between retries makes every attempt slower and
    /// less likely to succeed.
    static func joinWiFi(interface: String,
                         ssid: String,
                         password: String,
                         keepPoweredOn: Bool = false) -> Bool {
        // Snapshot the radio state BEFORE touching it.
        let wasOff = (wifiPowerState(interface: interface) == false)
        if joinWiFiAttempt(interface: interface, ssid: ssid, password: password) { return true }
        guard !keepPoweredOn, wasOff else { return false }
        // Restore the user's machine: an idle radio drains battery and
        // re-associates with random networks.
        _ = run("/usr/sbin/networksetup", ["-setairportpower", interface, "off"], timeout: 15)
        NetWatchLog.note("wifi restored to off after failed join")
        return false
    }

    /// The actual join sequence, without the failure cleanup.
    private static func joinWiFiAttempt(interface: String, ssid: String, password: String) -> Bool {
        // `nil` means the power state could not be parsed (localised output /
        // unknown interface). Treat it as "may need powering on" and still wait
        // for a stable On state, instead of joining a radio that is not ready.
        if wifiPowerState(interface: interface) != true {
            _ = wifiPowerOn(interface: interface)
            // Up to ~8 s for the radio to finish powering up.
            var powered = false
            for _ in 0..<16 {
                if wifiPowerState(interface: interface) == true { powered = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if !powered { return false }
            // Give the driver a moment to scan before asking it to join.
            Thread.sleep(forTimeInterval: 1.5)
        }

        // Already associated with the target: nothing to do (re-joining would
        // briefly drop a perfectly good link).
        if currentWiFiSSID(interface: interface) == ssid { return true }

        _ = run("/usr/sbin/networksetup", ["-setairportnetwork", interface, ssid, password], timeout: 25)
        // Association + DHCP can take a while after a radio cold start.
        for _ in 0..<40 {
            if currentWiFiSSID(interface: interface) == ssid { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: - VPN actions

    static func appExecutablePath(appPath: String) -> String? {
        Bundle(path: appPath)?.executableURL?.path
    }

    static func processRunning(appPath: String) -> Bool {
        run("/usr/bin/pgrep", ["-f", appPath]).succeeded
    }

    /// Which processes belong to the VPN app.
    ///
    /// `pgrep -f <appPath>` only matches the main executable (its argv holds
    /// the bundle path); the privileged helper and the connection workers carry
    /// other argv. They are matched by their executable directory instead, so
    /// a half-dead VPN (helper still holding the tunnel) is also cleared.
    private static func vpnProcessPIDs(appPath: String) -> [String] {
        guard !appPath.isEmpty else { return [] }
        var pids: [String] = []
        // Both forms are needed: the main executable's argv holds the bundle
        // path itself, while its helpers hold "<bundle>/Contents/…".
        for needle in [appPath, appPath + "/"] {
            let result = run("/usr/bin/pgrep", ["-f", needle])
            guard result.succeeded else { continue }
            for raw in result.trimmedOut.components(separatedBy: .newlines) {
                let value = raw.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !pids.contains(value) else { continue }
                // Guard against collateral damage: `pgrep -f` matches the FULL
                // command line, so an editor or a Finder window showing this
                // path would match too. Only real processes of this bundle
                // (executable inside "<app>/Contents/") are killed.
                guard processBelongsToBundle(pid: value, appPath: appPath) else {
                    NetWatchLog.note("skip pid \(value): not part of \(appPath)")
                    continue
                }
                pids.append(value)
            }
        }
        return pids
    }

    /// True when the process's executable lives inside the given bundle.
    ///
    /// The argv is matched as a PREFIX instead of being split on spaces: bundle
    /// paths routinely contain spaces ("OpenVPN Connect.app"), and
    /// `ps -o command=` shows the raw command line, so splitting turned
    /// "/Applications/OpenVPN Connect/…" into "/Applications/OpenVPN" and made
    /// every real VPN process look foreign.
    ///
    /// A PID that `ps` cannot describe is treated as a MATCH: it was listed by
    /// `pgrep` a moment ago, so it is either a process that just exited (killing
    /// it is harmless) or a permission-restricted helper (which must still be
    /// cleared). Refusing to kill those left a dead helper holding the tunnel.
    private static func processBelongsToBundle(pid: String, appPath: String) -> Bool {
        let result = run("/bin/ps", ["-p", pid, "-o", "command="])
        guard result.succeeded else { return true }
        let command = result.trimmedOut
        guard !command.isEmpty else { return true }
        return command.hasPrefix(appPath + "/")
    }

    /// SIGKILLs every process of the VPN app and waits for the tunnel to drop.
    ///
    /// This is the escalation path: `--quit` is asynchronous and silently does
    /// nothing when the GUI is wedged, which leaves the tunnel half-open and
    /// makes every later relaunch look like it "connected" while passing no
    /// traffic. A hard kill guarantees a clean slate.
    @discardableResult
    static func forceKillVPN(appPath: String) -> Bool {
        let pids = vpnProcessPIDs(appPath: appPath)
        NetWatchLog.note("force kill vpn pids=\(pids.joined(separator: ","))")
        guard !pids.isEmpty else { return true }

        _ = run("/bin/kill", ["-9"] + pids, timeout: 10)
        for _ in 0..<20 {
            if !processRunning(appPath: appPath) { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The helper may outlive the GUI; kill whatever is left, then wait for
        // the utun interface to disappear.
        let remaining = vpnProcessPIDs(appPath: appPath)
        if !remaining.isEmpty {
            _ = run("/bin/kill", ["-9"] + remaining, timeout: 10)
            Thread.sleep(forTimeInterval: 1)
        }
        for _ in 0..<10 {
            if !utunHasAddress() { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !processRunning(appPath: appPath)
    }

    /// Launches the VPN app and waits for the road abroad to actually work.
    /// `open -a` requires the FULL bundle path — an app name silently fails.
    ///
    /// Readiness is judged by `verifyURL` (the overseas link), not by a VPN
    /// service name: a VPN may be provided by any client, or the network itself
    /// may be a VPN, in which case no system service exists to query.
    static func launchVPN(appPath: String, verifyURL: String, waitSeconds: Int) -> Bool {
        guard !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) else {
            NetWatchLog.note("vpn launch failed: bundle missing at \(appPath)")
            return false
        }
        _ = run("/usr/bin/open", ["-a", appPath], timeout: 15)

        let deadline = Date().addingTimeInterval(TimeInterval(max(waitSeconds, 10)))
        while Date() < deadline {
            if httpProbe(url: verifyURL).reachable { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    /// Graceful attempt first (`--quit` + relaunch, the fast path that keeps the
    /// GUI session), then — only when that fails — a hard SIGKILL + relaunch.
    ///
    /// `hardFirst` skips the graceful step; it is what the watchdog uses when a
    /// HALF-OPEN tunnel is suspected (domestic internet up, VPN not connected).
    static func restartVPN(appPath: String,
                           verifyURL: String,
                           waitSeconds: Int,
                           hardFirst: Bool = false) -> Bool {
        guard !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) else {
            NetWatchLog.note("vpn restart failed: bundle missing at \(appPath)")
            return false
        }

        if hardFirst {
            NetWatchLog.note("vpn restart: hard kill first")
            forceKillVPN(appPath: appPath)
            if launchVPN(appPath: appPath, verifyURL: verifyURL, waitSeconds: waitSeconds) {
                NetWatchLog.note("vpn restart: connected after hard kill")
                return true
            }
            // One more full cycle: a cold-started client occasionally needs a
            // second launch to restore the profile session.
            NetWatchLog.note("vpn restart: retrying full cycle")
            forceKillVPN(appPath: appPath)
            let ok = launchVPN(appPath: appPath, verifyURL: verifyURL, waitSeconds: waitSeconds)
            NetWatchLog.note("vpn restart: \(ok ? "succeeded" : "failed") on retry")
            return ok
        }

        if let executable = appExecutablePath(appPath: appPath) {
            _ = run(executable, ["--quit"], timeout: 10)
            for _ in 0..<20 {
                if !processRunning(appPath: appPath) { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            // --quit silently no-ops on a wedged GUI: escalate immediately
            // instead of launching a second instance next to the stuck one.
            if processRunning(appPath: appPath) {
                NetWatchLog.note("vpn graceful quit timed out, escalating")
                forceKillVPN(appPath: appPath)
            }
            if launchVPN(appPath: appPath, verifyURL: verifyURL, waitSeconds: waitSeconds) {
                return true
            }
        }

        NetWatchLog.note("vpn restart: graceful path failed, hard kill + relaunch")
        forceKillVPN(appPath: appPath)
        return launchVPN(appPath: appPath, verifyURL: verifyURL, waitSeconds: waitSeconds)
    }

    // MARK: - App launch

    static func launchApp(path: String) -> Bool {
        run("/usr/bin/open", ["-a", path], timeout: 10).succeeded
    }
}
