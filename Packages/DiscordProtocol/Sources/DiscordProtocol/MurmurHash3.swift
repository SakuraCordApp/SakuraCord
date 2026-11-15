import Foundation

/// MurmurHash3 x86 32-bit with seed 0 over UTF-8, the hash Discord uses for
/// experiment names, experiment positions and member-list ids.
enum MurmurHash3 {
    static func hash(_ string: String) -> UInt32 {
        let data = Array(string.utf8)
        var hash: UInt32 = 0
        let count = data.count
        let blockCount = count / 4
        for block in 0 ..< blockCount {
            let offset = block * 4
            var key = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            key &*= 0xcc9e2d51
            key = (key << 15) | (key >> 17)
            key &*= 0x1b873593
            hash ^= key
            hash = (hash << 13) | (hash >> 19)
            hash = hash &* 5 &+ 0xe6546b64
        }
        var tail: UInt32 = 0
        let tailOffset = blockCount * 4
        switch count & 3 {
        case 3:
            tail ^= UInt32(data[tailOffset + 2]) << 16
            fallthrough
        case 2:
            tail ^= UInt32(data[tailOffset + 1]) << 8
            fallthrough
        case 1:
            tail ^= UInt32(data[tailOffset])
            tail &*= 0xcc9e2d51
            tail = (tail << 15) | (tail >> 17)
            tail &*= 0x1b873593
            hash ^= tail
        default:
            break
        }
        hash ^= UInt32(count)
        hash ^= hash >> 16
        hash &*= 0x85ebca6b
        hash ^= hash >> 13
        hash &*= 0xc2b2ae35
        hash ^= hash >> 16
        return hash
    }
}
