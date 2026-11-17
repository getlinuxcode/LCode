import Foundation
import LCodeKit

// lcode — LCode command-line tool. French option spellings (--dans, --sombre…) are kept as silent aliases.

let usage = """
Usage:
  lcode new <Name> [--bundle <id>] [--in <directory>]   create an iOS app project
  lcode open [<project>]             open the project in the LCode IDE
  lcode preview [<project>] [--index <n>] [--capture <png>] [--dark]   run a #Preview
  lcode run [<project>] [options]    run an xtool project (current directory by default)

Options:
  --device                 build and install on the connected iPhone (xtool)
  --device-model <name>    simulated device: iphone17promax (default), iphone16pro, iphonese
  --dark                   start in dark mode
  --capture <file.png>     render a screenshot without opening a window, then quit
  --taps "x,y;x,y"         simulated taps before the screenshot
  --wait <seconds>         let the app run this long before the screenshot (video, network…)
"""

/// LCode repository root (this file lives in Sources/lcode/).
let lcodeRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("lcode: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
// The IDE executable (lcode-ide) sits next to lcode.
if args.first == "open" {
    let ide = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("lcode-ide")
    let project = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
    let process = Process()
    process.executableURL = ide
    process.arguments = [project]
    do { try process.run() } catch { fail("cannot open the IDE (\(ide.path)): \(error)") }
    exit(0)
}
if args.first == "new" {
    guard args.count >= 2 else { fail("missing project name\n\n\(usage)") }
    let name = args[1]
    var bundle = "com.example.\(name)"
    var parent = FileManager.default.currentDirectoryPath
    var k = 2
    while k < args.count {
        if args[k] == "--bundle", k + 1 < args.count { bundle = args[k + 1]; k += 2; continue }
        if args[k] == "--in" || args[k] == "--dans", k + 1 < args.count { parent = args[k + 1]; k += 2; continue }
        fail("unknown option: \(args[k])")
    }
    do {
        let root = try Templates.createProject(name: name, bundleID: bundle, in: URL(fileURLWithPath: parent))
        print("▸ Project created: \(root.path)")
        exit(0)
    } catch { fail("\(error)") }
}

if args.first == "preview" {
    var path = FileManager.default.currentDirectoryPath
    var number = 0
    var capture: String?
    var dark = false
    var k = 1
    while k < args.count {
        switch args[k] {
        case "--index" where k + 1 < args.count, "--numero" where k + 1 < args.count: number = Int(args[k + 1]) ?? 0; k += 2
        case "--capture" where k + 1 < args.count: capture = args[k + 1]; k += 2
        case "--dark", "--sombre": dark = true; k += 1
        default: path = args[k]; k += 1
        }
    }
    do {
        let project = try XtoolProject.load(at: URL(fileURLWithPath: path).standardizedFileURL)
        let preview = PreviewBuild(project: project, lcodeRoot: lcodeRoot)
        let entries = try preview.prepare()
        guard !entries.isEmpty else { fail("no #Preview in app \(project.appTarget)") }
        for (n, e) in entries.enumerated() {
            print("\(n == number ? "▸" : " ") \(n) : \(e.file.lastPathComponent):\(e.preview.line)\(e.preview.name.map { " \"\($0)\"" } ?? "")")
        }
        let entry = entries[min(number, entries.count - 1)]
        let status = try Shell.run(["swift", "build", "--package-path", preview.directory.path, "--product", project.appTarget])
        guard status == 0 else { exit(status) }
        let bin = try Shell.capture(["swift", "build", "--package-path", preview.directory.path, "--show-bin-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var env = ["LSIM_PREVIEW_ID": entry.preview.symbol, "LSIM_DEVICE": "iphone17promax"].merging(project.simulatorEnvironment) { a, _ in a }
        if dark { env["LSIM_DARK"] = "1" }
        if let capture { env["LSIM_SCREENSHOT"] = capture; env["LSIM_SCREEN_ONLY"] = "1" }
        exit(try Shell.run([bin + "/" + project.appTarget], environment: env))
    } catch { fail("\(error)") }
}

guard args.first == "run" else { print(usage); exit(args.isEmpty || args.first == "--help" ? 0 : 1) }
args.removeFirst()

var options = SimulatorOptions()
var onDevice = false
var projectPath = FileManager.default.currentDirectoryPath
var i = 0
while i < args.count {
    let a = args[i]
    func value() -> String {
        i += 1
        guard i < args.count else { fail("missing value after \(a)") }
        return args[i]
    }
    switch a {
    case "--device": onDevice = true
    case "--device-model", "--appareil": options.device = value()
    case "--dark", "--sombre": options.dark = true
    case "--capture": options.screenshot = URL(fileURLWithPath: value()).path
    case "--taps", "--touchers": options.taps = value()
    case "--wait", "--attente":
        guard let s = Double(value()) else { fail("\(a): expected a number of seconds") }
        options.wait = s
    case "--help", "-h": print(usage); exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option: \(a)\n\n\(usage)") }
        projectPath = a
    }
    i += 1
}

do {
    let root = URL(fileURLWithPath: projectPath).standardizedFileURL
    let project = try XtoolProject.load(at: root)
    print("▸ Project \(project.name) — app: \(project.appTarget)\(project.bundleID.map { " (\($0))" } ?? "")")

    if onDevice {
        if !project.hasSDKVersionFix {
            print("""
            ⚠︎ Package.swift does not pass the SDK version to the linker: iOS will show the app in compatibility
              mode (without Liquid Glass). Add to the app target:
                linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios",
                                               "-Xlinker", "17.0", "-Xlinker", "27.3"])]
            """)
        }
        let connection = DeviceConnection.environment()
        print("▸ Building, signing and installing on the iPhone (xtool, \(connection.isEmpty ? "USB" : "USB or Wi-Fi"))…")
        let transport = DeviceConnection.transportFlag(connection)
        print("  (\(transport == "--usb" ? "USB" : "Wi-Fi"))")
        exit(try Shell.run(["xtool", "dev", "run", transport], cwd: project.root, environment: connection))
    }

    let build = SimulatorBuild(project: project, lcodeRoot: lcodeRoot)
    build.warnings.forEach { print("⚠︎ \($0)") }
    print("▸ Building for the simulator (\(build.directory.path))…")
    let status = try build.run(options)
    exit(status)
} catch {
    fail("\(error)")
}
