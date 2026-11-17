import Foundation
import LCodeKit

/// Destination d'exécution (comme le menu des appareils d'Xcode) : un simulateur ou un iPhone branché.
struct Destination: Equatable {
    enum Kind: Equatable { case simulator(String), device(udid: String, network: Bool) }
    let kind: Kind
    let title: String

    static let simulators: [Destination] = [
        Destination(kind: .simulator("iphone17promax"), title: "iPhone 17 Pro Max (simulateur)"),
        Destination(kind: .simulator("iphone16pro"), title: "iPhone 16 Pro (simulateur)"),
        Destination(kind: .simulator("iphonese"), title: "iPhone SE (simulateur)"),
    ]

    var simulatorID: String? { if case let .simulator(id) = kind { return id } else { return nil } }
}

/// Repère les iPhone en USB (usbmuxd) et sur le réseau (netmuxd), toutes les 4 secondes.
final class DeviceMonitor {
    private(set) var devices: [Destination] = []
    var onChange: ([Destination]) -> Void = { _ in }
    private var names: [String: String] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "lcode.appareils")

    func start() {
        poll()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            let usb = Set(Self.list([:]))
            let network = DeviceConnection.environment()
            let all = network.isEmpty ? usb : Set(Self.list(network))
            var found: [Destination] = []
            for udid in all.sorted() {
                let isUSB = usb.contains(udid)
                let name = self.names[udid] ?? Self.name(udid, isUSB ? [:] : network) ?? "iPhone"
                self.names[udid] = name
                found.append(Destination(kind: .device(udid: udid, network: !isUSB), title: "\(name) (\(isUSB ? "USB" : "Wi-Fi"))"))
            }
            onMain {
                guard found != self.devices else { return }
                self.devices = found
                self.onChange(found)
            }
        }
    }

    private static func list(_ env: [String: String]) -> [String] {
        let output = (try? run(["idevice_id", "-l"], env)) ?? ""
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func name(_ udid: String, _ env: [String: String]) -> String? {
        let output = (try? run(["ideviceinfo", "-u", udid, "-k", "DeviceName"], env))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
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
