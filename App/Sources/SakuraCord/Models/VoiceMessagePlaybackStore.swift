@preconcurrency import AVFoundation
import Foundation
import MediaPipeline
import MessageRendering
import Observation
import OSLog
import SakuraCordModels

nonisolated enum VoiceMessagePlaybackID: Hashable, Sendable {
    case message(MessageID)
    case composer(MessageComposerDestination)
    /// An audio file attachment in a message, played in its file card. A
    /// forward shows the same file in another message, with its own player.
    case attachment(MessageID, attachmentID: String)

    var isAudioFile: Bool {
        if case .attachment = self { true } else { false }
    }
}

/// Owns voice-message and audio-file playback for the timeline and composer
/// previews.
///
/// Like Discord, one voice message or audio file plays at a time; starting
/// another pauses the first. Speed is device-local and shared by every voice
/// message player; audio files play at normal speed and can be muted.
@MainActor
@Observable
final class VoiceMessagePlaybackStore {
    enum Source: Hashable {
        case local(URL)
        case remote(URL)
    }

    enum Phase: Equatable {
        case loading
        case playing
        case paused
    }

    private struct CachedPlayer {
        let source: Source
        let player: VoiceMessagePlayer
        let file: PlaybackFile
    }

    /// Discord's cycle order for the speed button.
    static let speeds: [Float] = [1, 1.5, 2, 0.75]
    static let speedDefaultsKey = "VoiceMessagePlaybackSpeed"
    static let maximumCachedPlayers = 4
    static let maximumPrefetchedURLs = 512
    /// Starts quicker than this show no spinner, so resuming doesn't flicker.
    static let startSpinnerDelay: Duration = .milliseconds(150)
    /// Discord remembers where up to 25 voice messages and audio files were left.
    static let maximumResumePositions = 25
    /// Audio files whose length, or failure to read it, is remembered.
    static let maximumKnownDurations = 128

    private(set) var activeID: VoiceMessagePlaybackID?
    private(set) var phase: Phase = .paused
    private(set) var speed: Float {
        didSet { applyOutput() }
    }
    /// Discord's audio file mute, which voice messages ignore.
    private(set) var isAudioFileMuted = false {
        didSet { applyOutput() }
    }

    @ObservationIgnored private var player: VoiceMessagePlayer?
    @ObservationIgnored private var playerFile: PlaybackFile?
    @ObservationIgnored private var activeSource: Source?
    @ObservationIgnored private var activeDuration: TimeInterval?
    @ObservationIgnored private var pausedPosition: TimeInterval = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Players for recently played messages, oldest first, kept
    /// open so returning to one starts at once.
    @ObservationIgnored private var cachedPlayers: [CachedPlayer] = []
    @ObservationIgnored private var prefetchedURLs: Set<URL> = []
    /// Durations learned by playing or measuring audio files, which arrive
    /// without one.
    @ObservationIgnored private var knownDurations: [Source: TimeInterval] = [:]
    @ObservationIgnored private var knownDurationOrder: [Source] = []
    /// Changes whenever a length is learned, so cached rows know to redraw.
    @ObservationIgnored private(set) var knownDurationsRevision = 0
    @ObservationIgnored private var measurements: [Source: Task<Void, Never>] = [:]
    /// When a file's length last couldn't be read, so moving the pointer over
    /// it waits before trying again rather than retrying on every move.
    @ObservationIgnored private var failedMeasurements: [Source: ContinuousClock.Instant] = [:]
    /// When play was last pressed, to tell a slow start from a quick one.
    @ObservationIgnored private var playRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored private var resumesAfterScrub = false
    @ObservationIgnored private var resumePositions: [VoiceMessagePlaybackID: TimeInterval] = [:]
    @ObservationIgnored private var resumeOrder: [VoiceMessagePlaybackID] = []
    @ObservationIgnored private let defaults: UserDefaults
    /// Re-signs an expiring Discord attachment link before it is fetched.
    @ObservationIgnored var resolveRemoteURL: (@MainActor (URL) async -> URL)?
    @ObservationIgnored var onError: (@MainActor (String) -> Void)?

    private static let logger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "VoiceMessagePlayback")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.float(forKey: Self.speedDefaultsKey)
        speed = Self.speeds.contains(stored) ? stored : 1
    }

    // MARK: Queries

    func isActive(_ id: VoiceMessagePlaybackID) -> Bool { activeID == id }

    func phase(of id: VoiceMessagePlaybackID) -> Phase? { activeID == id ? phase : nil }

    /// The live position of the active item, or a remembered position.
    func position(of id: VoiceMessagePlaybackID) -> TimeInterval {
        if activeID == id { return player?.isPlaying == true ? player?.currentTime ?? pausedPosition : pausedPosition }
        return resumePositions[id] ?? 0
    }

    func duration(of id: VoiceMessagePlaybackID) -> TimeInterval? {
        activeID == id ? player?.duration ?? activeDuration : nil
    }

    func knownDuration(of source: Source) -> TimeInterval? { knownDurations[source] }

    /// Whether `id` was pressed and still hasn't sounded, after a moment;
    /// a cached message opens too quickly to be worth a spinner.
    func isLoading(_ id: VoiceMessagePlaybackID) -> Bool {
        guard activeID == id, let playRequestedAt,
              ContinuousClock.now - playRequestedAt > Self.startSpinnerDelay
        else { return false }
        return phase == .loading || (phase == .playing && player?.isRendering == false)
    }

    var outputLevel: Float { phase == .playing ? player?.outputLevel ?? 0 : 0 }

    var speedLabel: String { Self.label(for: speed) }

    static func label(for speed: Float) -> String {
        switch speed {
        case 1.5: "1.5×"
        case 2: "2×"
        case 0.75: "0.75×"
        default: "1×"
        }
    }

    // MARK: Observation for AppKit

    /// Posted with the store as its object whenever the active item, its
    /// phase, position, or the speed changes. Timeline canvases observe it.
    static let didChange = Notification.Name("VoiceMessagePlaybackStore.didChange")

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Control

    func toggle(_ id: VoiceMessagePlaybackID, source: Source, duration: TimeInterval?) {
        if activeID == id {
            switch phase {
            case .playing: pause()
            case .loading: cancelActive(rememberingPosition: true)
            case .paused: play()
            }
            return
        }
        activate(id, source: source, duration: duration)
        play()
    }

    /// Moves the playhead; a paused message stays paused, as in Discord.
    func seek(_ id: VoiceMessagePlaybackID, source: Source, duration: TimeInterval?, fraction: Double) {
        if activeID != id { activate(id, source: source, duration: duration) }
        let total = self.duration(of: id) ?? duration ?? 0
        let target = min(max(0, fraction), 1) * total
        pausedPosition = target
        player?.seek(to: target)
        notify()
    }

    func beginScrub(_ id: VoiceMessagePlaybackID, source: Source, duration: TimeInterval?) {
        if activeID != id { activate(id, source: source, duration: duration) }
        resumesAfterScrub = phase == .playing
        if phase == .playing { pause() }
    }

    func endScrub(_ id: VoiceMessagePlaybackID) {
        guard activeID == id, resumesAfterScrub else { return }
        resumesAfterScrub = false
        play()
    }

    func toggleAudioFileMute() {
        isAudioFileMuted.toggle()
        notify()
    }

    /// Reads an audio file's length ahead of playing it, as Discord's player
    /// loads its metadata when the pointer reaches it.
    func measureDuration(of source: Source) {
        guard knownDurations[source] == nil,
              failedMeasurements[source].map({ ContinuousClock.now - $0 > .seconds(30) }) ?? true,
              measurements[source] == nil
        else { return }
        measurements[source] = Task { [weak self] in
            let duration = try? await Self.measuredDuration(of: source, resolve: self?.resolveRemoteURL)
            guard let self, !Task.isCancelled else { return }
            measurements[source] = nil
            guard let duration else {
                if failedMeasurements.count >= Self.maximumKnownDurations { failedMeasurements.removeAll() }
                failedMeasurements[source] = .now
                return
            }
            rememberDuration(duration, for: source)
            notify()
        }
    }

    func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 0
        speed = Self.speeds[(index + 1) % Self.speeds.count]
        defaults.set(speed, forKey: Self.speedDefaultsKey)
        notify()
    }

    /// Fetches a visible message into the media cache, like an image, so
    /// playing it doesn't wait for the download. Expired links are left
    /// for playback to re-sign.
    func prefetch(_ url: URL) {
        guard !DiscordAttachmentLink.needsRefresh(url, now: .now), prefetchedURLs.insert(url).inserted else { return }
        if prefetchedURLs.count > Self.maximumPrefetchedURLs { prefetchedURLs.removeAll() }
        Task.detached(priority: .utility) {
            _ = try? await SharedMediaDataLoader.shared.cachedFile(for: url, priority: .prefetch)
        }
    }

    /// Stops `id` if it is active, forgetting its position.
    func stop(_ id: VoiceMessagePlaybackID) {
        guard activeID == id else { return }
        cancelActive(rememberingPosition: false)
    }

    func stopAll() {
        cancelActive(rememberingPosition: false)
        cachedPlayers.removeAll()
        resumePositions.removeAll()
        resumeOrder.removeAll()
        measurements.values.forEach { $0.cancel() }
        measurements.removeAll()
        knownDurations.removeAll()
        knownDurationOrder.removeAll()
        failedMeasurements.removeAll()
    }

    // MARK: Internals

    private func activate(_ id: VoiceMessagePlaybackID, source: Source, duration: TimeInterval?) {
        cancelActive(rememberingPosition: true)
        activeID = id
        activeSource = source
        activeDuration = duration
        pausedPosition = position(ofInactive: id)
        phase = .paused
        notify()
    }

    private func position(ofInactive id: VoiceMessagePlaybackID) -> TimeInterval {
        resumePositions[id] ?? 0
    }

    private func play() {
        guard let id = activeID else { return }
        playRequestedAt = .now
        if let player {
            start(player)
            return
        }
        guard let source = activeSource else { return }
        if let index = cachedPlayers.firstIndex(where: { $0.source == source }) {
            let cached = cachedPlayers.remove(at: index)
            adopt(cached.player, file: cached.file, for: id)
            return
        }
        phase = .loading
        notify()
        loadTask = Task { [weak self] in
            do {
                let prepared = try await Self.preparePlayer(for: source, resolve: self?.resolveRemoteURL)
                try Task.checkCancellation()
                guard let self, self.activeID == id else { return }
                self.loadTask = nil
                self.adopt(prepared.player, file: prepared.file, for: id)
            } catch is CancellationError {
            } catch {
                guard let self, self.activeID == id else { return }
                Self.logger.error("Voice message playback failed: \(error.localizedDescription, privacy: .public)")
                self.loadTask = nil
                self.phase = .paused
                self.notify()
                self.onError?(Self.playbackFailure(for: id))
            }
        }
    }

    private func adopt(_ player: VoiceMessagePlayer, file: PlaybackFile, for id: VoiceMessagePlaybackID) {
        player.onFinish = { [weak self] in self?.finish(id) }
        player.onInterruption = { [weak self] in self?.interrupted(id) }
        self.player = player
        playerFile = file
        activeDuration = player.duration
        if let activeSource { rememberDuration(player.duration, for: activeSource) }
        applyOutput()
        if pausedPosition > 0 { player.seek(to: pausedPosition) }
        start(player)
    }

    private func start(_ player: VoiceMessagePlayer) {
        if pausedPosition >= player.duration - 0.05 { pausedPosition = 0 }
        player.seek(to: pausedPosition)
        do {
            try player.play()
            phase = .playing
        } catch {
            phase = .paused
            if let activeID { onError?(Self.playbackFailure(for: activeID)) }
        }
        notify()
    }

    private static func playbackFailure(for id: VoiceMessagePlaybackID) -> String {
        id.isAudioFile ? "This audio file couldn't be played." : "This voice message couldn't be played."
    }

    /// Voice messages take the chosen speed; audio files play at normal
    /// speed and follow the mute.
    private func applyOutput() {
        let isAudioFile = activeID?.isAudioFile == true
        player?.rate = isAudioFile ? 1 : speed
        player?.volume = isAudioFile && isAudioFileMuted ? 0 : 1
    }

    private func pause() {
        guard let player, phase == .playing else { return }
        player.pause()
        pausedPosition = player.currentTime
        phase = .paused
        notify()
    }

    private func interrupted(_ id: VoiceMessagePlaybackID) {
        guard activeID == id, let player, phase == .playing else { return }
        pausedPosition = player.currentTime
        phase = .paused
        notify()
    }

    private func finish(_ id: VoiceMessagePlaybackID) {
        guard activeID == id else { return }
        forgetResumePosition(id)
        if let player, let playerFile, let activeSource { cache(player, file: playerFile, for: activeSource) }
        player = nil
        playerFile = nil
        activeID = nil
        activeSource = nil
        activeDuration = nil
        pausedPosition = 0
        phase = .paused
        notify()
    }

    private func cancelActive(rememberingPosition: Bool) {
        guard let id = activeID else { return }
        loadTask?.cancel()
        loadTask = nil
        let position = player?.isPlaying == true ? player?.currentTime ?? pausedPosition : pausedPosition
        let duration = player?.duration ?? activeDuration ?? 0
        if let player, let playerFile, let activeSource { cache(player, file: playerFile, for: activeSource) }
        player = nil
        playerFile = nil
        // A composer preview's recording is about to go away.
        let isComposer = if case .composer = id { true } else { false }
        if !isComposer, rememberingPosition, position > 0.5, duration > 0, position < duration * 0.95 {
            rememberResumePosition(position, for: id)
        } else {
            forgetResumePosition(id)
        }
        activeID = nil
        activeSource = nil
        activeDuration = nil
        pausedPosition = 0
        phase = .paused
        notify()
    }

    /// Pauses a player that is no longer active and keeps it for a remote
    /// message; a composer preview's file is about to go away.
    private func cache(_ player: VoiceMessagePlayer, file: PlaybackFile, for source: Source) {
        player.onFinish = nil
        player.onInterruption = nil
        guard case .remote = source else {
            player.stop()
            return
        }
        player.pause()
        cachedPlayers.removeAll { $0.source == source }
        cachedPlayers.append(CachedPlayer(source: source, player: player, file: file))
        if cachedPlayers.count > Self.maximumCachedPlayers {
            cachedPlayers.removeFirst().player.stop()
        }
    }

    private func rememberResumePosition(_ position: TimeInterval, for id: VoiceMessagePlaybackID) {
        resumePositions[id] = position
        resumeOrder.removeAll { $0 == id }
        resumeOrder.append(id)
        while resumeOrder.count > Self.maximumResumePositions {
            resumePositions[resumeOrder.removeFirst()] = nil
        }
    }

    private func rememberDuration(_ duration: TimeInterval, for source: Source) {
        if knownDurations.updateValue(duration, forKey: source) != duration { knownDurationsRevision += 1 }
        knownDurationOrder.removeAll { $0 == source }
        knownDurationOrder.append(source)
        while knownDurationOrder.count > Self.maximumKnownDurations {
            knownDurations[knownDurationOrder.removeFirst()] = nil
        }
    }

    private func forgetResumePosition(_ id: VoiceMessagePlaybackID) {
        resumePositions[id] = nil
        resumeOrder.removeAll { $0 == id }
    }

    /// AVAudioFile needs a file, so remote audio plays from its file in the
    /// shared media cache, under the same budget and Clear Cache as images.
    private static func preparePlayer(
        for source: Source,
        resolve: (@MainActor (URL) async -> URL)?
    ) async throws -> (player: VoiceMessagePlayer, file: PlaybackFile) {
        switch source {
        case let .local(url):
            return (try VoiceMessagePlayer(fileURL: url), PlaybackFile(url: url))
        case let .remote(url):
            let resolved = await resolve?(url) ?? url
            if let file = try? await SharedMediaDataLoader.shared.cachedFile(for: resolved) {
                try Task.checkCancellation()
                // Cache eviction can race the open. Once open, AVAudioFile
                // retains its reader; otherwise use an owned copy below.
                if let player = try? VoiceMessagePlayer(fileURL: file) {
                    return (player, PlaybackFile(url: file))
                }
            }
            // Without a readable cached file, a private copy stands in.
            let data = try await SharedMediaDataLoader.shared.data(for: resolved)
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "SakuraCordVoicePlayback", directoryHint: .isDirectory)
            // The extension tells Core Audio the file's format.
            let fileURL = directory.appending(path: UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "ogg" : url.pathExtension)
            let file = PlaybackFile(url: fileURL, removesOnRelease: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return (try VoiceMessagePlayer(fileURL: fileURL), file)
        }
    }
}

private extension VoiceMessagePlaybackStore {
    /// The length of an audio file from its header; a remote file is read
    /// only as far as AVFoundation needs.
    static func measuredDuration(
        of source: Source,
        resolve: (@MainActor (URL) async -> URL)?
    ) async throws -> TimeInterval {
        switch source {
        case let .local(url):
            return try await Task.detached(priority: .utility) {
                let file = try AVAudioFile(forReading: url)
                return Double(file.length) / file.processingFormat.sampleRate
            }.value
        case let .remote(url):
            let duration = try await AVURLAsset(url: await resolve?(url) ?? url).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            return duration
        }
    }
}

/// A fallback copy lives only as long as its active or cached player.
/// Dropped loads and failed player initialization release it too.
private final class PlaybackFile {
    let url: URL
    private let removesOnRelease: Bool

    init(url: URL, removesOnRelease: Bool = false) {
        self.url = url
        self.removesOnRelease = removesOnRelease
    }

    deinit {
        if removesOnRelease { try? FileManager.default.removeItem(at: url) }
    }
}
