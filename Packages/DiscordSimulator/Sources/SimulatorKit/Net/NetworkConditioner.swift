import Foundation
import Synchronization

/// Adds reproducible latency and bandwidth limits so the app sees a realistic
/// network. Every connection draws from its own seeded stream, so the same
/// seed and request order give the same delays.
public final class NetworkConditioner: Sendable {
    public struct Profile: Sendable, Equatable, Codable {
        public var latencyMilliseconds: Double
        public var jitterMilliseconds: Double
        public var downloadBytesPerSecond: Double?
        public var uploadBytesPerSecond: Double?

        public init(
            latencyMilliseconds: Double,
            jitterMilliseconds: Double,
            downloadBytesPerSecond: Double? = nil,
            uploadBytesPerSecond: Double? = nil
        ) {
            self.latencyMilliseconds = latencyMilliseconds
            self.jitterMilliseconds = jitterMilliseconds
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadBytesPerSecond = uploadBytesPerSecond
        }

        public static let instant = Profile(latencyMilliseconds: 0, jitterMilliseconds: 0)
        /// The default: a home connection with a fixed delay and no jitter, so
        /// every run, benchmarks included, sees the same timings.
        public static let standard = Profile(
            latencyMilliseconds: 35, jitterMilliseconds: 0,
            downloadBytesPerSecond: 12_500_000, uploadBytesPerSecond: 2_500_000
        )
        public static let lan = Profile(latencyMilliseconds: 2, jitterMilliseconds: 0.5)
        public static let broadband = Profile(
            latencyMilliseconds: 35, jitterMilliseconds: 8,
            downloadBytesPerSecond: 12_500_000, uploadBytesPerSecond: 2_500_000
        )
        public static let mobile = Profile(
            latencyMilliseconds: 120, jitterMilliseconds: 40,
            downloadBytesPerSecond: 1_500_000, uploadBytesPerSecond: 400_000
        )

        public static func named(_ name: String) -> Profile? {
            switch name.lowercased() {
            case "instant": .instant
            case "standard": .standard
            case "lan": .lan
            case "broadband": .broadband
            case "mobile": .mobile
            default: nil
            }
        }
    }

    /// One injected HTTP delay, for checking that runs repeat.
    public struct DelayRecord: Sendable, Codable, Equatable {
        public var request: String
        public var occurrence: Int
        public var milliseconds: Double
    }

    private let random: SeededRandom
    private let current: Mutex<Profile>
    private let occurrences = Mutex<[String: Int]>([:])
    private let journal = Mutex<[DelayRecord]>([])

    public init(seed: UInt64, profile: Profile = .instant) {
        random = SeededRandom(seed: seed).fork("net")
        current = Mutex(profile)
    }

    /// The HTTP delay for a request. It is drawn from a stream keyed by the
    /// request and how many times it has been made, so the same requests get
    /// the same delays however the client spreads them over connections.
    func requestDelay(_ key: String, uploadBytes: Int) -> Duration {
        let profile = profile
        let occurrence = occurrences.withLock { counts in
            counts[key, default: 0] += 1
            return counts[key]!
        }
        var stream = random.fork("\(key)#\(occurrence)")
        let delay = ConnectionShaper.latency(&stream, profile) + ConnectionShaper.transfer(uploadBytes, at: profile.uploadBytesPerSecond)
        if profile != .instant {
            let record = DelayRecord(request: key, occurrence: occurrence, milliseconds: Double(delay.components.attoseconds) / 1e15 + Double(delay.components.seconds) * 1000)
            journal.withLock { records in
                records.append(record)
                if records.count > 10_000 { records.removeFirst(records.count - 10_000) }
            }
        }
        return delay
    }

    /// Delays injected so far, oldest first.
    public var delays: [DelayRecord] { journal.withLock { $0 } }

    public var profile: Profile { current.withLock { $0 } }

    public func setProfile(_ profile: Profile) { current.withLock { $0 = profile } }

    func shaper(server: String, connection ordinal: Int) -> ConnectionShaper {
        ConnectionShaper(conditioner: self, random: random.fork("\(server)#\(ordinal)"))
    }
}

/// One connection's share of the conditioner.
final class ConnectionShaper: Sendable {
    private struct State {
        var random: SeededRandom
        var nextMessageStart: ContinuousClock.Instant?
    }

    private let conditioner: NetworkConditioner
    private let state: Mutex<State>

    init(conditioner: NetworkConditioner, random: SeededRandom) {
        self.conditioner = conditioner
        state = Mutex(State(random: random))
    }

    /// When the next server→client WebSocket message may start: its own delay,
    /// but never before the previous message has finished, so order holds.
    func messageStart(bytes: Int) -> ContinuousClock.Instant {
        let profile = conditioner.profile
        return state.withLock { state in
            let now = ContinuousClock.now
            let start = max(state.nextMessageStart ?? now, now + Self.latency(&state.random, profile))
            state.nextMessageStart = start + Self.transfer(bytes, at: profile.downloadBytesPerSecond)
            return start
        }
    }

    /// Writes `data` paced to the download rate; one plain write when unlimited.
    func write(_ data: Data, to channel: TCPChannel) async throws {
        guard let rate = conditioner.profile.downloadBytesPerSecond, rate > 0 else {
            try await channel.send(data)
            return
        }
        let clock = ContinuousClock()
        let began = clock.now
        var offset = 0
        while offset < data.count {
            let end = min(offset + 16 * 1024, data.count)
            try await channel.send(data.subdata(in: offset ..< end))
            offset = end
            try await Task.sleep(until: began + .seconds(Double(offset) / rate), clock: clock)
        }
    }

    /// Always consumes one draw, so a connection's sequence stays aligned even
    /// when the profile changes mid-run.
    static func latency(_ random: inout SeededRandom, _ profile: NetworkConditioner.Profile) -> Duration {
        let jitter = (random.unit() * 2 - 1) * profile.jitterMilliseconds
        return .milliseconds(max(0, profile.latencyMilliseconds + jitter))
    }

    static func transfer(_ bytes: Int, at rate: Double?) -> Duration {
        guard let rate, rate > 0 else { return .zero }
        return .seconds(Double(bytes) / rate)
    }
}
