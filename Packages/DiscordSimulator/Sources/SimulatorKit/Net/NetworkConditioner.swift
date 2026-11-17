import Foundation
import Synchronization

/// The delays every host adds: Discord's measured answer time plus a connection's round trip,
/// or one custom profile everywhere.
public enum SimulatedNetwork: Sendable, Equatable {
    case uniform(NetworkConditioner.Profile)
    /// Each host's measured answer time plus `roundTripMilliseconds`, drawn per request from a
    /// log-normal curve of `spread` (0 for fixed delays).
    case connection(roundTripMilliseconds: Double, spread: Double, downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?)

    /// The home connection the measurement was made on, with Discord's variance.
    public static let realistic = connection(roundTripMilliseconds: 30, spread: 0.3,
                                             downloadBytesPerSecond: 12_500_000, uploadBytesPerSecond: 2_500_000)
    /// The same connection with every delay fixed at its median, so benchmark runs compare.
    public static let standard = connection(roundTripMilliseconds: 30, spread: 0,
                                            downloadBytesPerSecond: 12_500_000, uploadBytesPerSecond: 2_500_000)
    /// A connection right next to Discord: only Discord's own time and variance.
    public static let lan = connection(roundTripMilliseconds: 2, spread: 0.25, downloadBytesPerSecond: nil, uploadBytesPerSecond: nil)
    /// Mobile data: a longer, less steady round trip and slow transfers.
    public static let mobile = connection(roundTripMilliseconds: 100, spread: 0.45,
                                          downloadBytesPerSecond: 1_500_000, uploadBytesPerSecond: 400_000)
    public static let instant = uniform(.instant)

    public static func named(_ name: String) -> SimulatedNetwork? {
        switch name.lowercased() {
        case "realistic": .realistic
        case "standard": .standard
        case "lan": .lan
        case "mobile": .mobile
        case "instant": .instant
        default: nil
        }
    }

    /// Measured from a signed-in session (Nov 2026): REST answers took a median 275 ms (240–780 ms) over a
    /// ~30 ms round trip, so about 245 ms is Discord's servers; CDN images about 33 ms, nearly all round trip.
    /// Estimated: about 10 ms of storage time for uploads, and half a round trip for Gateway and voice messages.
    func profile(for port: DiscordSimulator.Port) -> NetworkConditioner.Profile {
        switch self {
        case let .uniform(profile):
            return profile
        case let .connection(roundTrip, spread, download, upload):
            let median: Double = switch port {
            case .api: 245 + roundTrip
            case .cdn, .media, .activity: 3 + roundTrip
            case .upload: 10 + roundTrip
            case .gateway, .voice, .voiceMedia, .control: roundTrip / 2
            }
            return NetworkConditioner.Profile(latencyMilliseconds: median, jitterMilliseconds: 0, latencySpread: spread,
                                              downloadBytesPerSecond: download, uploadBytesPerSecond: upload)
        }
    }
}

/// Adds reproducible latency and bandwidth limits so the app sees a realistic
/// network. Every connection draws from its own seeded stream, so the same
/// seed and request order give the same delays.
public final class NetworkConditioner: Sendable {
    public struct Profile: Sendable, Equatable, Codable {
        public var latencyMilliseconds: Double
        public var jitterMilliseconds: Double
        /// Spread of a log-normal curve around `latencyMilliseconds` (its median); 0 for a fixed delay.
        public var latencySpread: Double
        public var downloadBytesPerSecond: Double?
        public var uploadBytesPerSecond: Double?

        public init(
            latencyMilliseconds: Double,
            jitterMilliseconds: Double,
            latencySpread: Double = 0,
            downloadBytesPerSecond: Double? = nil,
            uploadBytesPerSecond: Double? = nil
        ) {
            self.latencyMilliseconds = latencyMilliseconds
            self.jitterMilliseconds = jitterMilliseconds
            self.latencySpread = latencySpread
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadBytesPerSecond = uploadBytesPerSecond
        }

        public static let instant = Profile(latencyMilliseconds: 0, jitterMilliseconds: 0)
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

    /// Always consumes three draws, so a connection's sequence stays aligned even
    /// when the profile changes mid-run.
    static func latency(_ random: inout SeededRandom, _ profile: NetworkConditioner.Profile) -> Duration {
        let jitter = (random.unit() * 2 - 1) * profile.jitterMilliseconds
        // Box–Muller: a standard normal draw, for the log-normal spread.
        let normal = (-2 * log(1 - random.unit())).squareRoot() * cos(2 * .pi * random.unit())
        return .milliseconds(max(0, profile.latencyMilliseconds * exp(profile.latencySpread * normal) + jitter))
    }

    static func transfer(_ bytes: Int, at rate: Double?) -> Duration {
        guard let rate, rate > 0 else { return .zero }
        return .seconds(Double(bytes) / rate)
    }
}
