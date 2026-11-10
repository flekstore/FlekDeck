//
//  FlekJITReport.swift
//  LiveContainerSwiftUI
//
//  A report on built-in JIT's setup, for a user to send to support when the
//  check will not pass.
//
//  Why a check failed is often only said by the device itself — the disk
//  image it would not mount, the session it closed — and a user's device
//  cannot be connected to a computer to read its log. So the report is made by
//  running the check again while the device's log is recorded, and holds what
//  FlekDeck knows of the setup, each step of the check as it went, and the
//  lines of the device's log from the services built-in JIT goes through.
//
//  It is a text file, shared from the share sheet, read by people.
//

import Foundation
import Network
import UIKit

final class FlekJITReport: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var steps: [String] = []
    private var lastStage = -1
    private var lastPercent = -1
    private var deviceLog: LCDeviceLog?
    private let vpn: String

    /// - Parameter vpn: The VPN's state as the page knows it, which is read on
    ///   the main actor.
    init(vpn: String) {
        self.vpn = vpn
    }

    // MARK: Recording

    /// Starts recording the device's log, and waits until it is read or could
    /// not be, so that the check is in it from its start. On the queue the
    /// check runs on, after the VPN has been turned on for it.
    func startDeviceLog() {
        guard LCDeviceLog.isAvailable else {
            note("Device log: not available in this build")
            return
        }
        let log = LCDeviceLog(pairingFile: LCPath.pairingFilePath, keep: Self.isKept)
        deviceLog = log
        log.start()
        if log.waitUntilRecording(withTimeout: 10) {
            note("Device log: recording")
        } else {
            note("Device log: not recording — \(log.failure ?? "no answer within 10 s")")
        }
    }

    /// A line for the steps, with how long into the check it came.
    func note(_ line: String) {
        let seconds = Date().timeIntervalSince(startedAt)
        lock.lock()
        steps.append(String(format: "+%6.2fs  %@", seconds, line))
        lock.unlock()
    }

    /// The check's own progress, in StikJITPreflight's stages, noted when the
    /// stage changes and every tenth of the way through a download or mount.
    func noteStage(_ stage: Int, _ fraction: Double) {
        let percent = fraction < 0 ? -1 : Int(fraction * 100)
        lock.lock()
        let isNew = stage != lastStage || (percent >= 0 && percent / 10 != lastPercent / 10)
        if isNew {
            lastStage = stage
            lastPercent = percent
        }
        lock.unlock()
        guard isNew else { return }
        let name: String
        switch stage {
        case 0: name = "Connecting to the device"
        case 1: name = "Checking the developer disk image"
        case 2: name = "Downloading the developer disk image"
        case 3: name = "Mounting the developer disk image"
        case 4: name = "Verifying the mount"
        case 5: name = "Ready"
        default: name = "Stage \(stage)"
        }
        note(percent >= 0 ? "\(name) \(percent)%" : name)
    }

    /// Ends the recording, a moment after the check so that what the device
    /// logged about its end is in, and writes the report. On the check's queue.
    func finish(result: String) -> URL? {
        note("Result: \(result)")
        if let deviceLog {
            Thread.sleep(forTimeInterval: 2)
            deviceLog.stop()
        }
        let text = render(result: result)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlekJIT Report \(formatter.string(from: startedAt)).txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    // MARK: Device log

    /// The processes built-in JIT goes through: the device's pairing and
    /// service directory, the disk image mounter and what it asks, the code
    /// signing check, the debug server, the VPN, and FlekDeck itself. Lower
    /// case.
    private static let keptProcesses: Set<String> = [
        "lockdownd", "remoted", "remotepairingd", "remotepairingdatavaultd",
        "mobile_storage_proxy", "mobilestoragemounter", "storagekitd", "mobileactivationd",
        "amfid", "debugserver", "installd",
        "nesessionmanager", "neagent", "nehelper",
        "loopbackvpn", ProcessInfo.processInfo.processName.lowercased(),
    ]

    /// Words that mark a line from elsewhere as being about the same things.
    private static let keptWords = [
        "developerdiskimage", "personaliz", "mobilestorage", "mobile_storage", "trustcache", "trust cache",
        "amfi", "developer mode", "developermode", "debugserver", "remotepairing", "coredevice",
    ]

    /// A line of the relay reads "Nov 10 11:08:12 iPhone process(library)[pid]
    /// <Level>: message", where the device's name may have spaces of its own,
    /// so the sender is the first word ending in "[pid]". Kept if it is one of
    /// the processes above, or speaks of what they do. The kernel is too busy
    /// to keep whole.
    static func isKept(_ line: String) -> Bool {
        let header = line.split(separator: "<", maxSplits: 1).first ?? Substring(line)
        if let sender = header.split(separator: " ").first(where: { $0.contains("[") && $0.hasSuffix("]") }) {
            let name = sender.prefix { $0 != "[" && $0 != "(" }.lowercased()
            if keptProcesses.contains(name) {
                return true
            }
        }
        let lowered = line.lowercased()
        return keptWords.contains { lowered.contains($0) }
    }

    // MARK: Rendering

    private func render(result: String) -> String {
        var text = "FlekJIT Report\n"
        text += String(repeating: "=", count: 14) + "\n\n"
        text += setup().map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        text += "\n\nResult: \(result)\n"

        lock.lock()
        let steps = steps
        lock.unlock()
        text += "\nCheck\n-----\n" + steps.joined(separator: "\n") + "\n"

        text += "\nDevice log\n----------\n"
        if let deviceLog {
            let lines = deviceLog.lines
            if let failure = deviceLog.failure {
                text += "(\(failure))\n"
            }
            text += lines.isEmpty ? "(no lines kept)\n" : lines.joined(separator: "\n") + "\n"
        } else {
            text += "(not recorded)\n"
        }
        return text
    }

    /// What FlekDeck knows of the device and the setup, as label and value.
    private func setup() -> [(String, String)] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"

        var rows: [(String, String)] = [
            ("Date", formatter.string(from: startedAt)),
            ("FlekDeck", version),
            ("Device", Self.modelIdentifier),
            ("iOS", UIDevice.current.systemVersion),
            ("Pairing file", Self.pairingFileSummary),
            ("VPN", vpn),
            ("Network", Self.networkSummary),
        ]
        rows.append(("Disk image cache", Self.diskImageSummary))
        return rows
    }

    private static var modelIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static var pairingFileSummary: String {
        let url = LCPath.pairingFilePath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "none"
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        var parts = [FlekBuiltInJIT.isPairingFileMadeOnDevice ? "made on this device" : "imported", "\(size) bytes"]
        if let date = attributes[.modificationDate] as? Date {
            parts.append("saved \(ISO8601DateFormatter().string(from: date))")
        }
        if let data = try? Data(contentsOf: url),
           let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            parts.append(FlekBuiltInJIT.isUsablePairingFile(record) ? "RemotePairing record" : "no RemotePairing record")
            if record["HostID"] != nil {
                parts.append("with lockdown record")
            }
        } else {
            parts.append("unreadable")
        }
        return parts.joined(separator: ", ")
    }

    /// Which interface the traffic goes out on, and whether the device
    /// answers through the VPN.
    private static var networkSummary: String {
        let semaphore = DispatchSemaphore(value: 0)
        var summary = "unknown"
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            var kinds: [String] = []
            if path.usesInterfaceType(.wifi) { kinds.append("Wi-Fi") }
            if path.usesInterfaceType(.cellular) { kinds.append("mobile data") }
            if path.usesInterfaceType(.wiredEthernet) { kinds.append("wired") }
            if path.usesInterfaceType(.other) { kinds.append("other (VPN)") }
            summary = "\(path.status == .satisfied ? "online" : "offline")\(kinds.isEmpty ? "" : ", " + kinds.joined(separator: ", "))"
            if path.isExpensive { summary += ", expensive" }
            if path.isConstrained { summary += ", Low Data Mode" }
            semaphore.signal()
        }
        let queue = DispatchQueue(label: "com.fs.flekdeck.jitReport.path")
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 1)
        monitor.cancel()
        return queue.sync { summary }
    }

    private static var diskImageSummary: String {
        let folder = LCUtils.builtInJITFolder().appendingPathComponent("DMG")
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: folder.path), !files.isEmpty else {
            return "empty"
        }
        return files.sorted().compactMap { name -> String? in
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            return "\(name) (\(size) bytes)"
        }.joined(separator: "; ")
    }
}
