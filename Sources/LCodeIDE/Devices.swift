import CAdw
import Foundation
import LCodeKit

/// Run destination (like Xcode's device menu): a simulator or a connected iPhone.
struct Destination: Equatable {
    enum Kind: Equatable { case simulator(String), device(udid: String, network: Bool) }
    let kind: Kind
    /// Device name, without the connection suffix.
    let name: String
    let title: String

    static let simulators: [Destination] = [
        simulator("iphone17promax", "iPhone 17 Pro Max"),
        simulator("iphone16pro", "iPhone 16 Pro"),
        simulator("iphonese", "iPhone SE"),
    ]

    private static func simulator(_ id: String, _ name: String) -> Destination {
        Destination(kind: .simulator(id), name: name, title: tr("%@ (Simulator)", name))
    }

    var simulatorID: String? { if case let .simulator(id) = kind { return id } else { return nil } }
}

/// Polls for iPhones over USB (usbmuxd) and the network (netmuxd) every 4 seconds.
final class DeviceMonitor {
    private(set) var devices: [Destination] = []
    var onChange: ([Destination]) -> Void = { _ in }
    private var names: [String: String] = [:]
    private let queue = DispatchQueue(label: "lcode.devices")

    func start() {
        poll()
        // GTK timer: Foundation Timers never fire, the IDE runs GTK's main loop and not RunLoop.main.
        final class Box { weak var monitor: DeviceMonitor?; init(_ m: DeviceMonitor) { monitor = m } }
        let tick: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            let box = Unmanaged<Box>.fromOpaque(data!)
            guard let monitor = box.takeUnretainedValue().monitor else { box.release(); return 0 }
            monitor.poll()
            return 1
        }
        g_timeout_add(4000, tick, Unmanaged.passRetained(Box(self)).toOpaque())
    }

    /// A scan in progress (scans can take seconds when a device stops answering): don't stack them.
    private var polling = false

    private func poll() {
        guard !polling else { return }
        polling = true
        queue.async { [weak self] in
            guard let self else { return }
            let usb = Set(Self.list([:], network: false))
            let network = DeviceConnection.environment()
            // `idevice_id -l` only reports USB devices; Wi-Fi ones (through netmuxd) need `-n`.
            let wifi = network.isEmpty ? [] : Set(Self.list(network, network: true))
            let all = usb.union(wifi)
            var found: [Destination] = []
            for udid in all.sorted() {
                let isUSB = usb.contains(udid)
                let name = self.names[udid] ?? Self.name(udid, isUSB ? [:] : network, network: !isUSB) ?? "iPhone"
                self.names[udid] = name
                found.append(Destination(kind: .device(udid: udid, network: !isUSB), name: name, title: "\(name) (\(isUSB ? "USB" : "Wi-Fi"))"))
            }
            onMain {
                self.polling = false
                guard found != self.devices else { return }
                self.devices = found
                self.onChange(found)
            }
        }
    }

    private static func list(_ env: [String: String], network: Bool) -> [String] {
        let output = (try? run(["idevice_id", network ? "-n" : "-l"], env)) ?? ""
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func name(_ udid: String, _ env: [String: String], network: Bool) -> String? {
        let output = (try? run(["ideviceinfo", "-u", udid] + (network ? ["-n"] : []) + ["-k", "DeviceName"], env))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Over Wi-Fi, lockdownd often refuses ideviceinfo: the device is then shown as "iPhone (Wi-Fi)".
        // Not `xtool devices` as a fallback: launched from the IDE it never returns.
        if let output, !output.isEmpty, !output.hasPrefix("ERROR") { return output }
        return nil
    }

    private static func run(_ args: [String], _ env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Never wait on the IDE's stdin, and give up on a device that stops answering.
        p.arguments = ["timeout", "8"] + args
        p.standardInput = FileHandle.nullDevice
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
