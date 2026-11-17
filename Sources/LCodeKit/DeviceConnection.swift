import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// iPhone access over USB **or Wi-Fi**.
///
/// The system `usbmuxd` only knows USB. LCode runs `netmuxd` (from ~/.local/share/lcode/bin) as a relay:
/// it forwards USB to `usbmuxd` and adds iPhones announced on the local network (paired once over USB,
/// Wi-Fi sync enabled). Tools (xtool, libimobiledevice) reach it through `USBMUXD_SOCKET_ADDRESS`.
public enum DeviceConnection {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 27015
    public static var netmuxd: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/lcode/bin/netmuxd")
    }

    /// Environment to pass to xtool; starts netmuxd if needed. Empty when netmuxd is not installed (USB only).
    public static func environment() -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: netmuxd) else { return [:] }
        if !isListening() {
            startNetmuxd()
            for _ in 0..<30 where !isListening() { usleep(100_000) }
        }
        return isListening() ? ["USBMUXD_SOCKET_ADDRESS": "\(host):\(port)"] : [:]
    }

    /// Transport flag for `xtool dev run`: USB when plugged in (faster), otherwise Wi-Fi.
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

    /// Starts netmuxd detached, so it outlives the lcode command.
    static func startNetmuxd() {
        let log = (NSHomeDirectory() as NSString).appendingPathComponent(".local/share/lcode/netmuxd.log")
        let command = "nohup '\(netmuxd)' --disable-unix --host \(host) --port \(port) "
            + "--plist-storage /var/lib/lockdown --upstream-usbmuxd /var/run/usbmuxd >> '\(log)' 2>&1 &"
        _ = try? Shell.run(["bash", "-c", command])
    }
}
