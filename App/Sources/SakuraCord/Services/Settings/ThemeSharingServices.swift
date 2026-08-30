import Foundation

nonisolated struct SakuraCordSharedTheme: Equatable, Hashable, Sendable {
    let appearance: AppColorScheme
    let theme: SakuraCordGradientTheme
}

nonisolated enum SakuraCordThemeShareDecodeResult: Equatable, Sendable {
    case current(SakuraCordSharedTheme)
    case requiresNewerClient(preview: SakuraCordSharedTheme?)
}

nonisolated enum SakuraCordThemeShareCodec {
    static let transportVersion: UInt8 = 1
    static let readerVersion: UInt8 = 1

    private static let maximumTokenLength = 256
    private static let fixedHeaderLength = 3
    private static let scalarByteCount = 2
    private static let checksumByteCount = 2

    enum EncodingError: Error {
        case invalidURL
        case unsupportedReaderVersion
    }

    static func shareURL(for sharedTheme: SakuraCordSharedTheme) throws -> URL {
        let token = try token(for: sharedTheme)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "sakuracord.app"
        components.path = "/settings/themes/\(token)"
        guard let url = components.url else { throw EncodingError.invalidURL }
        return url
    }

    static func token(
        for sharedTheme: SakuraCordSharedTheme,
        minimumReaderVersion: UInt8 = readerVersion
    ) throws -> String {
        guard minimumReaderVersion > 0 else {
            throw EncodingError.unsupportedReaderVersion
        }

        let theme = sharedTheme.theme
        let sharedColors = theme.activeColors
        let flags = sharedTheme.appearance.shareCode
            | (UInt8(sharedColors.count - 1) << 2)
            | (UInt8(sharedColors.count - 1) << 5)

        var bytes = [transportVersion, minimumReaderVersion, flags]
        bytes.append(contentsOf: encodedUnitScalar(theme.intensity))
        bytes.append(contentsOf: encodedUnitScalar(theme.brightness))
        for color in sharedColors {
            bytes.append(contentsOf: encodedUnitScalar(color.hue))
            bytes.append(contentsOf: encodedUnitScalar(color.saturation))
        }
        bytes.append(contentsOf: encodedChecksum(for: bytes))
        return Data(bytes).base64URLEncodedString
    }

    static func decode(_ token: String) -> SakuraCordThemeShareDecodeResult? {
        guard !token.isEmpty,
              token.count <= maximumTokenLength,
              let data = Data(base64URLEncoded: token)
        else { return nil }

        let bytes = [UInt8](data)
        guard let version = bytes.first else { return nil }
        if version > transportVersion {
            return .requiresNewerClient(preview: nil)
        }
        guard version == transportVersion,
              bytes.count >= fixedHeaderLength
                  + scalarByteCount * 4
                  + checksumByteCount
        else { return nil }

        let minimumReaderVersion = bytes[1]
        let flags = bytes[2]
        let storedColorCount = Int((flags >> 5) & 0b111) + 1
        let activeColorCount = Int((flags >> 2) & 0b111) + 1
        guard minimumReaderVersion > 0,
              let appearance = AppColorScheme(shareCode: flags & 0b11),
              storedColorCount >= SakuraCordGradientTheme.minimumColorCount,
              storedColorCount <= SakuraCordGradientTheme.maximumColorCount,
              activeColorCount >= SakuraCordGradientTheme.minimumColorCount,
              activeColorCount <= storedColorCount
        else { return nil }

        let knownPayloadEnd = fixedHeaderLength
            + scalarByteCount * 2
            + storedColorCount * scalarByteCount * 2
        guard bytes.count >= knownPayloadEnd + checksumByteCount else {
            return nil
        }
        let checksumIndex = bytes.count - checksumByteCount
        if minimumReaderVersion <= readerVersion,
           checksumIndex != knownPayloadEnd
        {
            return nil
        }
        guard decodedUInt16(bytes, at: checksumIndex)
            == crc16(bytes[..<checksumIndex])
        else { return nil }

        var offset = fixedHeaderLength
        let intensity = decodedUnitScalar(bytes, at: &offset)
        let brightness = decodedUnitScalar(bytes, at: &offset)
        var colors: [SakuraCordThemeColor] = []
        colors.reserveCapacity(storedColorCount)
        for _ in 0 ..< storedColorCount {
            colors.append(SakuraCordThemeColor(
                hue: decodedUnitScalar(bytes, at: &offset),
                saturation: decodedUnitScalar(bytes, at: &offset)
            ))
        }

        let sharedTheme = SakuraCordSharedTheme(
            appearance: appearance,
            theme: SakuraCordGradientTheme(
                colors: colors,
                activeColorCount: activeColorCount,
                intensity: intensity,
                brightness: brightness
            )
        )
        if minimumReaderVersion > readerVersion {
            return .requiresNewerClient(preview: sharedTheme)
        }
        return .current(sharedTheme)
    }

    private static func encodedUnitScalar(_ value: Double) -> [UInt8] {
        let encoded = UInt16((min(max(value, 0), 1) * 65_535).rounded())
        return [UInt8(encoded >> 8), UInt8(encoded & 0xFF)]
    }

    private static func decodedUnitScalar(
        _ bytes: [UInt8],
        at offset: inout Int
    ) -> Double {
        defer { offset += scalarByteCount }
        return Double(decodedUInt16(bytes, at: offset)) / 65_535
    }

    private static func decodedUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func encodedChecksum(for bytes: [UInt8]) -> [UInt8] {
        let checksum = crc16(bytes[...])
        return [UInt8(checksum >> 8), UInt8(checksum & 0xFF)]
    }

    private static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var checksum: UInt16 = 0xFFFF
        for byte in bytes {
            checksum ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                checksum = checksum & 0x8000 == 0
                    ? checksum << 1
                    : (checksum << 1) ^ 0x1021
            }
        }
        return checksum
    }
}

private nonisolated extension AppColorScheme {
    var shareCode: UInt8 {
        switch self {
        case .system: 0
        case .light: 1
        case .dark: 2
        }
    }

    init?(shareCode: UInt8) {
        switch shareCode {
        case 0: self = .system
        case 1: self = .light
        case 2: self = .dark
        default: return nil
        }
    }
}

private nonisolated extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        guard string.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }) else { return nil }

        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}
