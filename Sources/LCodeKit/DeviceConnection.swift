import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Accès à l'iPhone en USB **ou en Wi-Fi**.
///
/// Le service système `usbmuxd` ne connaît que l'USB. LCode lance à côté `netmuxd` (dans
/// ~/.local/share/lcode/bin), en mode relais : il transmet l'USB à `usbmuxd` et ajoute les iPhone
/// annoncés sur le réseau local (appairés une fois en USB, synchronisation Wi-Fi active).
/// Les outils (xtool, libimobiledevice) y accèdent via `USBMUXD_SOCKET_ADDRESS`.
public enum DeviceConnection {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 27015
    public static var netmuxd: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/lcode/bin/netmuxd")
    }

    /// Variables d'environnement à passer à xtool ; démarre netmuxd au besoin.
    /// Renvoie un dictionnaire vide si netmuxd n'est pas installé (USB seul, comportement d'origine).
    public static func environment() -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: netmuxd) else { return [:] }
        if !isListening() {
            startNetmuxd()
            for _ in 0..<30 where !isListening() { usleep(100_000) }
        }
        return isListening() ? ["USBMUXD_SOCKET_ADDRESS": "\(host):\(port)"] : [:]
    }

    /// Option de transport pour `xtool dev run` : l'USB s'il est branché (plus rapide), sinon le Wi-Fi.
    public static func transportFlag(_ environment: [String: String]) -> String {
        if environment.isEmpty { return "--usb" }
        let usb = (try? Shell.capture(["idevice_id", "-l"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return usb.isEmpty ? "--network" : "--usb"
    }

    static func isListening() -> Bool {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Lance netmuxd en arrière-plan, détaché (il survit à la commande lcode).
    static func startNetmuxd() {
        let log = (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/lcode/netmuxd.log")
        let command = "nohup '\(netmuxd)' --disable-unix --host \(host) --port \(port) "
            + "--plist-storage /var/lib/lockdown --upstream-usbmuxd /var/run/usbmuxd >> '\(log)' 2>&1 &"
        _ = try? Shell.run(["bash", "-c", command])
    }
}
