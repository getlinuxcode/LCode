@_exported import CoreMedia
@_exported import CoreVideo
import Combine
import Foundation

// AVFoundation pour le simulateur LSim : AVPlayer, AVPlayerItem, AVAsset, AVAudioPlayer, AVAudioSession.
// La lecture est réelle (MediaEngine, par ffmpeg) ; l'image est affichée par `VideoPlayer` (AVKit) ou par
// toute vue qui lit `AVPlayer._currentFrame`.

// MARK: - AVAsset

public struct AVAsyncProperty<Root, Value>: Sendable {
    let name: String
    let read: @Sendable (Root) async throws -> Value
}

extension AVAsyncProperty where Root == AVAsset, Value == CMTime {
    public static var duration: AVAsyncProperty<AVAsset, CMTime> {
        AVAsyncProperty(name: "duration") { asset in try await asset.loadDuration() }
    }
}

extension AVAsyncProperty where Root == AVAsset, Value == Bool {
    public static var isPlayable: AVAsyncProperty<AVAsset, Bool> {
        AVAsyncProperty(name: "isPlayable") { asset in (try? await asset.loadInfo()) != nil }
    }
}

open class AVAsset: @unchecked Sendable {
    let engine: MediaEngine

    public init(url: URL) { engine = MediaEngine(url: url) }

    func loadInfo() async throws -> MediaEngine.Info {
        let engine = self.engine
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try engine.probe()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func loadDuration() async throws -> CMTime {
        let info = try await loadInfo()
        return info.duration.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .indefinite
    }

    public func load<T>(_ property: AVAsyncProperty<AVAsset, T>) async throws -> T {
        try await property.read(self)
    }

    public func load<A, B>(_ a: AVAsyncProperty<AVAsset, A>, _ b: AVAsyncProperty<AVAsset, B>) async throws -> (A, B) {
        (try await a.read(self), try await b.read(self))
    }

    /// Ancienne API synchrone (bloquante).
    public var duration: CMTime {
        (try? engine.probe().duration).flatMap { $0 }.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .indefinite
    }

    public var isPlayable: Bool { (try? engine.probe()) != nil }
}

public final class AVURLAsset: AVAsset, @unchecked Sendable {
    public let url: URL
    public init(url: URL, options: [String: Any]? = nil) {
        self.url = url
        super.init(url: url)
    }
}

// MARK: - Observation clé-valeur

#if !canImport(Darwin)
/// Options d'observation (absentes de Foundation sous Linux) : acceptées pour compiler, `publisher(for:)`
/// émet toujours la valeur initiale puis chaque changement.
public struct NSKeyValueObservingOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let new = NSKeyValueObservingOptions(rawValue: 1)
    public static let old = NSKeyValueObservingOptions(rawValue: 2)
    public static let initial = NSKeyValueObservingOptions(rawValue: 4)
    public static let prior = NSKeyValueObservingOptions(rawValue: 8)
}
#endif

// MARK: - AVPlayerItem

extension Notification.Name {
    public static let AVPlayerItemDidPlayToEndTime = Notification.Name("AVPlayerItemDidPlayToEndTimeNotification")
    public static let AVPlayerItemFailedToPlayToEndTime = Notification.Name("AVPlayerItemFailedToPlayToEndTimeNotification")
    public static let AVPlayerItemPlaybackStalled = Notification.Name("AVPlayerItemPlaybackStalledNotification")
}

public final class AVPlayerItem: @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown, readyToPlay, failed }

    public let asset: AVAsset
    public private(set) var status: Status = .unknown { didSet { changed.send() } }
    public private(set) var error: Error?
    public private(set) var duration: CMTime = .indefinite { didSet { changed.send() } }
    public private(set) var presentationSize: CGSize = .zero
    let changed = PassthroughSubject<Void, Never>()

    public convenience init(url: URL) { self.init(asset: AVURLAsset(url: url)) }

    public init(asset: AVAsset, automaticallyLoadedAssetKeys: [String]? = nil) {
        self.asset = asset
        Thread.detachNewThread { [weak self] in self?.prepare() }
    }

    var engine: MediaEngine { asset.engine }

    private func prepare() {
        do {
            let info = try engine.probe()
            DispatchQueue.main.async {
                self.duration = info.duration.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .indefinite
                self.presentationSize = CGSize(width: info.width, height: info.height)
                self.status = .readyToPlay
            }
        } catch {
            DispatchQueue.main.async {
                self.error = error
                self.status = .failed
                print("[AVFoundation] \(error)")
            }
        }
    }

    public func currentTime() -> CMTime { CMTime(seconds: engine.position, preferredTimescale: 600) }

    public func publisher<V>(for keyPath: KeyPath<AVPlayerItem, V>, options: NSKeyValueObservingOptions = [.initial, .new])
        -> AnyPublisher<V, Never> {
        Just(()).merge(with: changed).map { [unowned self] _ in self[keyPath: keyPath] }.eraseToAnyPublisher()
    }
}

// MARK: - AVPlayer

open class AVPlayer: @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown, readyToPlay, failed }
    public enum TimeControlStatus: Int, Sendable { case paused, waitingToPlayAtSpecifiedRate, playing }
    public enum ActionAtItemEnd: Int, Sendable { case advance, pause, none }

    public private(set) var currentItem: AVPlayerItem?
    public var actionAtItemEnd: ActionAtItemEnd = .pause
    public var automaticallyWaitsToMinimizeStalling = true
    public var allowsExternalPlayback = true
    public var preventsDisplaySleepDuringVideoPlayback = true
    public private(set) var timeControlStatus: TimeControlStatus = .paused { didSet { changed.send() } }
    public var status: Status {
        switch currentItem?.status {
        case .readyToPlay: return .readyToPlay
        case .failed: return .failed
        default: return .unknown
        }
    }
    public var error: Error? { currentItem?.error }

    public var rate: Float {
        get { timeControlStatus == .paused ? 0 : 1 }
        set { if newValue > 0 { play() } else { pause() } }
    }
    public var defaultRate: Float = 1

    public var volume: Float = 1 { didSet { restartIfPlaying() } }
    public var isMuted = false { didSet { restartIfPlaying() } }

    /// Dernière image décodée (pour VideoPlayer et les vues qui affichent la vidéo).
    public private(set) var _currentFrame: CVPixelBuffer?
    /// Une nouvelle image est arrivée (sur le fil principal).
    public let _frames = PassthroughSubject<CVPixelBuffer, Never>()
    let changed = PassthroughSubject<Void, Never>()

    private var observers: [UUID: (interval: Double, queue: DispatchQueue, block: (CMTime) -> Void, timer: DispatchSourceTimer)] = [:]
    private var boundaryObservers: [UUID: DispatchSourceTimer] = [:]
    private var wantsPlay = false
    private var itemToken: AnyCancellable?

    public init() {}
    public convenience init(url: URL) { self.init(playerItem: AVPlayerItem(url: url)) }
    public init(playerItem item: AVPlayerItem?) {
        replaceCurrentItem(with: item)
    }

    public func replaceCurrentItem(with item: AVPlayerItem?) {
        currentItem?.engine.stop()
        timeControlStatus = .paused
        _currentFrame = nil
        currentItem = item
        guard let item else { changed.send(); return }
        item.engine.onFrame = { [weak self] frame in
            DispatchQueue.main.async {
                guard let self, self.currentItem === item else { return }
                self._currentFrame = frame
                self._frames.send(frame)
            }
        }
        item.engine.onEnd = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.currentItem === item else { return }
                self.wantsPlay = false
                self.timeControlStatus = .paused
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            }
        }
        // Première image (vignette) dès que le média est décrit, et lecture différée si play() est déjà demandé.
        itemToken = item.changed.sink { [weak self, weak item] in
            guard let self, let item, item.status == .readyToPlay else { return }
            self.changed.send()
            if self.wantsPlay, self.timeControlStatus != .playing { self.startEngine() }
            if self._currentFrame == nil, !self.wantsPlay { item.engine.still(at: 0) }
        }
        changed.send()
    }

    public func play() {
        wantsPlay = true
        guard let item = currentItem else { return }
        if item.status == .readyToPlay { startEngine() } else { timeControlStatus = .waitingToPlayAtSpecifiedRate }
    }

    public func pause() {
        wantsPlay = false
        currentItem?.engine.pause()
        timeControlStatus = .paused
    }

    public func playImmediately(atRate rate: Float) { play() }

    private func startEngine() {
        guard let item = currentItem else { return }
        var start = item.engine.position
        if let d = item.engine.info?.duration, start >= d - 0.05 { start = 0 }
        do {
            try item.engine.start(at: start, volume: isMuted ? 0 : volume)
            timeControlStatus = .playing
        } catch {
            print("[AVFoundation] \(error)")
            timeControlStatus = .paused
        }
    }

    private func restartIfPlaying() {
        if timeControlStatus == .playing { startEngine() }
    }

    public func currentTime() -> CMTime { currentItem?.currentTime() ?? .zero }

    public func seek(to time: CMTime) { seek(to: time, completionHandler: { _ in }) }

    public func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) { seek(to: time) }

    public func seek(to time: CMTime, completionHandler: @escaping (Bool) -> Void) {
        guard let item = currentItem, time.isNumeric else { completionHandler(false); return }
        let target = max(0, time.seconds)
        if timeControlStatus == .playing {
            do { try item.engine.start(at: target, volume: isMuted ? 0 : volume) } catch { completionHandler(false); return }
        } else {
            item.engine.setPosition(target)
            item.engine.still(at: target)
        }
        changed.send()
        completionHandler(true)
    }

    public func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                     completionHandler: @escaping (Bool) -> Void) {
        seek(to: time, completionHandler: completionHandler)
    }

    @discardableResult
    public func seek(to time: CMTime) async -> Bool {
        await withCheckedContinuation { c in seek(to: time) { c.resume(returning: $0) } }
    }

    // MARK: Observateurs de temps

    public func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?,
                                        using block: @escaping (CMTime) -> Void) -> Any {
        let id = UUID()
        let q = queue ?? .main
        let timer = DispatchSource.makeTimerSource(queue: q)
        let seconds = max(0.02, interval.seconds.isFinite ? interval.seconds : 0.5)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.timeControlStatus == .playing else { return }
            block(self.currentTime())
        }
        timer.resume()
        observers[id] = (seconds, q, block, timer)
        return id
    }

    public func addBoundaryTimeObserver(forTimes times: [NSValue], queue: DispatchQueue?, using block: @escaping () -> Void) -> Any {
        UUID()
    }

    public func removeTimeObserver(_ observer: Any) {
        guard let id = observer as? UUID else { return }
        observers.removeValue(forKey: id)?.timer.cancel()
    }

    public func publisher<V>(for keyPath: KeyPath<AVPlayer, V>, options: NSKeyValueObservingOptions = [.initial, .new])
        -> AnyPublisher<V, Never> {
        Just(()).merge(with: changed).map { [unowned self] _ in self[keyPath: keyPath] }.eraseToAnyPublisher()
    }

    deinit {
        observers.values.forEach { $0.timer.cancel() }
        currentItem?.engine.stop()
    }
}

/// File de lecture (enchaîne les éléments).
public final class AVQueuePlayer: AVPlayer, @unchecked Sendable {
    private var queue: [AVPlayerItem] = []
    private var endToken: NSObjectProtocol?

    public init(items: [AVPlayerItem]) {
        super.init(playerItem: items.first)
        queue = Array(items.dropFirst())
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: nil) {
            [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.currentItem else { return }
            self.advanceToNextItem()
            self.play()
        }
    }

    public override init() { super.init() }

    public func items() -> [AVPlayerItem] { (currentItem.map { [$0] } ?? []) + queue }
    public func advanceToNextItem() { replaceCurrentItem(with: queue.isEmpty ? nil : queue.removeFirst()) }
    public func insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) { queue.append(item) }
    public func remove(_ item: AVPlayerItem) { queue.removeAll { $0 === item } }
    public func removeAllItems() { queue = []; replaceCurrentItem(with: nil) }
}

/// Boucle un élément (`AVPlayerLooper(player:templateItem:)`).
public final class AVPlayerLooper {
    private var token: NSObjectProtocol?
    public init(player: AVQueuePlayer, templateItem: AVPlayerItem) {
        player.replaceCurrentItem(with: templateItem)
        token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: templateItem, queue: nil) {
            [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }
    public func disableLooping() { token.map(NotificationCenter.default.removeObserver); token = nil }
}

// MARK: - AVAudioPlayer

public protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?)
}

extension AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {}
    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {}
}

open class AVAudioPlayer: @unchecked Sendable {
    public let url: URL?
    public weak var delegate: AVAudioPlayerDelegate?
    public var numberOfLoops = 0
    public var volume: Float = 1 { didSet { if isPlaying { _ = play() } } }
    public var enableRate = false
    public var rate: Float = 1
    public var pan: Float = 0
    public private(set) var isPlaying = false
    private let engine: MediaEngine
    private var loopsDone = 0

    public init(contentsOf url: URL) throws {
        self.url = url
        engine = MediaEngine(url: url)
        _ = try engine.probe()
        engine.onEnd = { [weak self] in DispatchQueue.main.async { self?.ended() } }
    }

    public convenience init(contentsOf url: URL, fileTypeHint: String?) throws { try self.init(contentsOf: url) }

    public convenience init(data: Data, fileTypeHint: String? = nil) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lsim-son-\(UUID().uuidString)")
        try data.write(to: file)
        try self.init(contentsOf: file)
    }

    public var duration: TimeInterval { (try? engine.probe().duration).flatMap { $0 } ?? 0 }
    public var currentTime: TimeInterval {
        get { engine.position }
        set { engine.setPosition(newValue); if isPlaying { _ = play() } }
    }

    public func prepareToPlay() -> Bool { (try? engine.probe()) != nil }

    @discardableResult
    public func play() -> Bool {
        do {
            try engine.start(at: engine.position >= duration - 0.05 ? 0 : engine.position, volume: volume)
            isPlaying = true
            return true
        } catch {
            print("[AVFoundation] \(error)")
            return false
        }
    }

    public func pause() { engine.pause(); isPlaying = false }
    public func stop() { engine.pause(); isPlaying = false }

    private func ended() {
        if numberOfLoops < 0 || loopsDone < numberOfLoops {
            loopsDone += 1
            engine.setPosition(0)
            _ = play()
            return
        }
        isPlaying = false
        loopsDone = 0
        delegate?.audioPlayerDidFinishPlaying(self, successfully: true)
    }
}

// MARK: - AVAudioSession (sans effet dans le simulateur)

public final class AVAudioSession: @unchecked Sendable {
    public struct Category: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let ambient = Category(rawValue: "AVAudioSessionCategoryAmbient")
        public static let soloAmbient = Category(rawValue: "AVAudioSessionCategorySoloAmbient")
        public static let playback = Category(rawValue: "AVAudioSessionCategoryPlayback")
        public static let record = Category(rawValue: "AVAudioSessionCategoryRecord")
        public static let playAndRecord = Category(rawValue: "AVAudioSessionCategoryPlayAndRecord")
        public static let multiRoute = Category(rawValue: "AVAudioSessionCategoryMultiRoute")
    }

    public struct Mode: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let `default` = Mode(rawValue: "AVAudioSessionModeDefault")
        public static let moviePlayback = Mode(rawValue: "AVAudioSessionModeMoviePlayback")
        public static let spokenAudio = Mode(rawValue: "AVAudioSessionModeSpokenAudio")
        public static let voiceChat = Mode(rawValue: "AVAudioSessionModeVoiceChat")
        public static let videoRecording = Mode(rawValue: "AVAudioSessionModeVideoRecording")
        public static let measurement = Mode(rawValue: "AVAudioSessionModeMeasurement")
    }

    public struct CategoryOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mixWithOthers = CategoryOptions(rawValue: 1)
        public static let duckOthers = CategoryOptions(rawValue: 2)
        public static let allowBluetooth = CategoryOptions(rawValue: 4)
        public static let defaultToSpeaker = CategoryOptions(rawValue: 8)
        public static let allowAirPlay = CategoryOptions(rawValue: 64)
        public static let allowBluetoothA2DP = CategoryOptions(rawValue: 32)
    }

    public struct SetActiveOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }

    public enum RouteSharingPolicy: UInt, Sendable { case `default`, longFormAudio, longFormVideo, independent }

    nonisolated(unsafe) private static let instance = AVAudioSession()
    public static func sharedInstance() -> AVAudioSession { instance }

    public private(set) var category: Category = .soloAmbient
    public private(set) var mode: Mode = .default
    public var outputVolume: Float { 1 }
    public var sampleRate: Double { 48000 }
    public var isOtherAudioPlaying: Bool { false }

    public func setCategory(_ category: Category) throws { self.category = category }
    public func setCategory(_ category: Category, options: CategoryOptions = []) throws { self.category = category }
    public func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {
        self.category = category
        self.mode = mode
    }
    public func setCategory(_ category: Category, mode: Mode, policy: RouteSharingPolicy, options: CategoryOptions = []) throws {
        self.category = category
        self.mode = mode
    }
    public func setMode(_ mode: Mode) throws { self.mode = mode }
    public func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}

    public static let interruptionNotification = Notification.Name("AVAudioSessionInterruptionNotification")
    public static let routeChangeNotification = Notification.Name("AVAudioSessionRouteChangeNotification")
}

// MARK: - Divers

public enum AVLayerVideoGravity: String, Sendable {
    case resize = "AVLayerVideoGravityResize"
    case resizeAspect = "AVLayerVideoGravityResizeAspect"
    case resizeAspectFill = "AVLayerVideoGravityResizeAspectFill"
}

public enum AVMediaType: String, Sendable {
    case video = "vide", audio = "soun", text = "text", subtitle = "sbtl"
}
