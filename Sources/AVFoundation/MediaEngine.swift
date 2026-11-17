import CoreVideo
import Foundation

/// Real media playback in the simulator through the system `ffmpeg`:
/// - video: decoded to BGRA at a fixed rate over a pipe, frames paced by the clock;
/// - audio: decoded to 16-bit PCM and played by `paplay` (PulseAudio / PipeWire).
/// Pause and seeking restart both processes at the new position (simple and robust).
final class MediaEngine: @unchecked Sendable {
    struct Info {
        var duration: Double?
        var width = 0, height = 0
        var frameRate = 30.0
        var hasVideo = false
        var hasAudio = false
    }

    enum Failure: Error, CustomStringConvertible {
        case missingTool(String)
        case unreadable(String)
        var description: String {
            switch self {
            case let .missingTool(t): return "\(t) not found: install it (sudo apt install ffmpeg) to play media in the simulator."
            case let .unreadable(m): return "Unreadable media: \(m)"
            }
        }
    }

    let url: URL
    private(set) var info: Info?
    /// New frame (called on a background thread).
    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    /// End of media reached (called on a background thread).
    var onEnd: () -> Void = {}

    private let lock = NSLock()
    private var processes: [Process] = []
    private var generation = 0
    private var anchorPosition = 0.0
    private var anchorDate: Date?
    private var volume: Float = 1

    /// Decoded frames are downscaled beyond this width: the simulated screen is small.
    static let maxWidth = 960
    static let maxFrameRate = 30.0

    init(url: URL) { self.url = url }

    var input: String { url.isFileURL ? url.path : url.absoluteString }

    // MARK: - Probing

    static func tool(_ name: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Duration, size, frame rate, tracks (ffprobe). Blocking: call off the main thread.
    func probe() throws -> Info {
        if let info { return info }
        guard let ffprobe = Self.tool("ffprobe") else { throw Failure.missingTool("ffprobe") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", input]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadable(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var info = Info()
        if let d = (json["format"] as? [String: Any])?["duration"] as? String { info.duration = Double(d) }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "video" where !info.hasVideo && (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1:
                info.hasVideo = true
                info.width = stream["width"] as? Int ?? 0
                info.height = stream["height"] as? Int ?? 0
                if let rate = stream["avg_frame_rate"] as? String ?? stream["r_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] > 0, parts[0] > 0 { info.frameRate = parts[0] / parts[1] }
                }
            case "audio":
                info.hasAudio = true
            default:
                break
            }
        }
        lock.lock(); self.info = info; lock.unlock()
        return info
    }

    /// Output frame size (even dimensions, capped width).
    var outputSize: (Int, Int) {
        guard let info, info.width > 0, info.height > 0 else { return (0, 0) }
        let w = min(Self.maxWidth, info.width) / 2 * 2
        let h = max(2, Int((Double(w) * Double(info.height) / Double(info.width) / 2).rounded()) * 2)
        return (w, h)
    }

    // MARK: - Position

    var position: Double {
        lock.lock(); defer { lock.unlock() }
        guard let anchorDate else { return anchorPosition }
        return anchorPosition + Date().timeIntervalSince(anchorDate)
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return anchorDate != nil }

    // MARK: - Playback

    func start(at position: Double, volume: Float) throws {
        let info = try probe()
        guard let ffmpeg = Self.tool("ffmpeg") else { throw Failure.missingTool("ffmpeg") }
        stopProcesses()
        lock.lock()
        generation += 1
        let gen = generation
        anchorPosition = max(0, position)
        anchorDate = Date()
        self.volume = volume
        lock.unlock()

        let seek = ["-ss", String(format: "%.3f", max(0, position))]
        if info.hasVideo {
            let (w, h) = outputSize
            let fps = min(Self.maxFrameRate, info.frameRate)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-nostdin", "-loglevel", "error"] + seek + ["-i", input, "-map", "0:v:0",
                           "-vf", "fps=\(fps),scale=\(w):\(h)", "-f", "rawvideo", "-pix_fmt", "bgra", "-"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            add(p)
            let handle = out.fileHandleForReading
            Thread.detachNewThread { [weak self] in
                self?.pumpVideo(handle, width: w, height: h, fps: fps, start: max(0, position), generation: gen)
            }
        }
        if info.hasAudio, volume > 0, let paplay = Self.tool("paplay") ?? Self.tool("pw-play") {
            let decoder = Process()
            decoder.executableURL = URL(fileURLWithPath: ffmpeg)
            decoder.arguments = ["-nostdin", "-loglevel", "error"] + seek + ["-i", input, "-map", "0:a:0", "-vn",
                                 "-af", "volume=\(volume)", "-f", "s16le", "-ac", "2", "-ar", "48000", "-"]
            let player = Process()
            player.executableURL = URL(fileURLWithPath: paplay)
            player.arguments = paplay.hasSuffix("paplay")
                ? ["--raw", "--rate=48000", "--channels=2", "--format=s16le", "--client-name=LSim"]
                : ["--rate", "48000", "--channels", "2", "--format", "s16", "-"]
            let pipe = Pipe()
            decoder.standardOutput = pipe
            decoder.standardError = FileHandle.nullDevice
            player.standardInput = pipe
            player.standardError = FileHandle.nullDevice
            try decoder.run()
            try player.run()
            add(decoder)
            add(player)
            if !info.hasVideo {
                // Audio only: the end comes when the player has played everything.
                Thread.detachNewThread { [weak self] in
                    player.waitUntilExit()
                    guard let self, self.isCurrent(gen) else { return }
                    self.finish(gen)
                }
            }
        }
    }

    /// A single frame at `position` without playing (seeking while paused).
    func still(at position: Double) {
        guard let info = try? probe(), info.hasVideo, let ffmpeg = Self.tool("ffmpeg") else { return }
        let (w, h) = outputSize
        Thread.detachNewThread { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-nostdin", "-loglevel", "error", "-ss", String(format: "%.3f", max(0, position)),
                           "-i", self?.input ?? "", "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=\(w):\(h)",
                           "-f", "rawvideo", "-pix_fmt", "bgra", "-"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if data.count >= w * h * 4 {
                self?.onFrame(CVPixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data.prefix(w * h * 4)))
            }
        }
    }

    /// Stops playback, keeping the reached position.
    func pause() {
        let current = position
        lock.lock()
        generation += 1
        anchorPosition = current
        anchorDate = nil
        lock.unlock()
        stopProcesses()
    }

    func stop() {
        pause()
    }

    func setPosition(_ position: Double) {
        lock.lock(); anchorPosition = max(0, position); if anchorDate != nil { anchorDate = Date() }; lock.unlock()
    }

    // MARK: - Internals

    private func add(_ p: Process) { lock.lock(); processes.append(p); lock.unlock() }

    private func isCurrent(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return gen == generation }

    private func stopProcesses() {
        lock.lock()
        let ps = processes
        processes = []
        lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }

    private func finish(_ gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        if let anchorDate { anchorPosition += Date().timeIntervalSince(anchorDate) }
        if let d = info?.duration { anchorPosition = d }
        anchorDate = nil
        generation += 1
        lock.unlock()
        stopProcesses()
        onEnd()
    }

    /// Reads frames from the pipe and publishes them on time (a full pipe throttles ffmpeg).
    private func pumpVideo(_ handle: FileHandle, width: Int, height: Int, fps: Double, start: Double, generation gen: Int) {
        let frameBytes = width * height * 4
        var buffer = Data()
        var index = 0
        while isCurrent(gen) {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while buffer.count >= frameBytes, isCurrent(gen) {
                let frame = buffer.prefix(frameBytes)
                buffer.removeFirst(frameBytes)
                let due = start + Double(index) / fps
                index += 1
                let wait = due - position
                if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 1)) }
                // More than a frame late: skip to catch up with the clock.
                if position - due > 1.5 / fps { continue }
                onFrame(CVPixelBuffer(width: width, height: height, bytesPerRow: width * 4, data: Data(frame)))
            }
        }
        // Video stream ended: wait out the duration (audio may run slightly longer).
        guard isCurrent(gen) else { return }
        if let d = info?.duration, d - position > 0.05 { Thread.sleep(forTimeInterval: min(d - position, 2)) }
        finish(gen)
    }
}
