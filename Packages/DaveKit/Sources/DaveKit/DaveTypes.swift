public enum DaveMediaType: Sendable {
    case audio
    case video
}

public enum DaveCodec: Sendable {
    case opus
    case vp8
    case vp9
    case h264
    case h265
    case av1
}
