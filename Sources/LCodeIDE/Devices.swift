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
    private var timer: Timer?
    private let queue = DispatchQueue(label: "lcode.devices")

    func start() {
        poll()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
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
        if let output, !output.isEmpty, !output.hasPrefix("ERROR") { return output }
        // Over Wi-Fi, lockdownd often refuses ideviceinfo; xtool still knows the name ("Name [network]: UDID").
        let xtool = (try? run(["xtool", "devices"], env)) ?? ""
        for line in xtool.split(separator: "\n") where line.hasSuffix(udid) {
            if let bracket = line.range(of: " [") { return String(line[..<bracket.lowerBound]) }
        }
        return nil
    }

    private static func run(_ args: [String], _ env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
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
