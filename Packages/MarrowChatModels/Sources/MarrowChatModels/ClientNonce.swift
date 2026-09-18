import Foundation
import Synchronization

public enum ClientNonce {
    /// Discord message nonces use the same timestamp layout as snowflakes.
    /// The upper 42 bits are milliseconds since Discord's 2015 epoch, not Unix
    /// milliseconds. A local 12-bit sequence keeps multiple messages created in
    /// the same millisecond distinct without fabricating worker or process IDs.
    public static let discordEpochMilliseconds: UInt64 = 1_420_070_400_000
    private static let sequenceState = Mutex((millisecond: UInt64(0), sequence: UInt16(0)))

    public static func make(now: Date = .now) -> String {
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        guard milliseconds >= discordEpochMilliseconds else { return "0" }
        let sequence = sequenceState.withLock { state -> UInt16 in
            if state.millisecond == milliseconds {
                state.sequence = (state.sequence + 1) & 0x0FFF
            } else {
                state.millisecond = milliseconds
                state.sequence = 0
            }
            return state.sequence
        }
        return String(((milliseconds - discordEpochMilliseconds) << 22) | UInt64(sequence))
    }
}
