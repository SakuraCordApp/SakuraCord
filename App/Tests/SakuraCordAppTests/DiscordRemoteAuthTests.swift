import AppKit
import DiscordProtocol
import Foundation
@testable import SakuraCord
import Testing
import Vision

struct DiscordRemoteAuthTests {
    @Test func `decodes paicord remote auth V 2 fixtures`() throws {
        let hello = try JSONDecoder().decode(
            DiscordRemoteAuthPayload.self,
            from: Data(#"{"op":"hello","heartbeat_interval":41250}"#.utf8)
        )
        #expect(hello.op == .hello)
        #expect(hello.heartbeatInterval == 41250)

        let pending = try JSONDecoder().decode(
            DiscordRemoteAuthPayload.self,
            from: Data(#"{"op":"pending_remote_init","fingerprint":"server-issued"}"#.utf8)
        )
        #expect(pending.op == .pendingRemoteInit)
        #expect(pending.fingerprint == "server-issued")
    }

    @Test func `creates official remote auth URL without inventing values`() {
        #expect(
            DiscordRemoteAuthManager.qrCodeURL(fingerprint: "server-issued")?.absoluteString
                == "https://discord.com/ra/server-issued"
        )
        #expect(DiscordRemoteAuthManager.qrCodeURL(fingerprint: "") == nil)
    }

    @Test func `decodes scanned user and nonce proof encoding`() {
        let user = DiscordRemoteAuthManager.decodeUser(Data("1234:0:avatar-hash:pink:user".utf8))
        #expect(user == DiscordRemoteAuthUser(
            id: "1234",
            discriminator: "0",
            avatar: "avatar-hash",
            username: "pink:user"
        ))
        #expect(DiscordRemoteAuthManager.base64URL(Data([0xFB, 0xFF])) == "-_8")
    }

    @Test func `remote auth socket uses only paicord header set`() throws {
        var request = try URLRequest(url: #require(URL(string: "wss://remote-auth-gateway.discord.gg/?v=2")))
        DiscordClientMetadata(
            locale: "en-US",
            acceptLanguage: "en-US"
        ).applyRemoteAuthWebSocketHeaders(to: &request)

        #expect(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty == false)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://discord.com")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US")
        #expect(request.value(forHTTPHeaderField: "X-Super-Properties") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Fingerprint") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test @MainActor func `styled QR code has no inset background and still decodes`() throws {
        let url = try #require(URL(string: "https://discord.com/ra/sanitized-fixture"))
        let image = try #require(DiscordQRCodeRenderer.render(url: url))
        var proposedRect = CGRect(origin: .zero, size: image.size)
        let transparentCode = try #require(image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil))

        let provider = try #require(transparentCode.dataProvider)
        let data = try #require(provider.data)
        let bytes = CFDataGetBytePtr(data)
        let alphaOffset = transparentCode.alphaInfo == .premultipliedFirst ? 0 : 3
        #expect(bytes?[alphaOffset] == 0)

        let width = transparentCode.width
        let height = transparentCode.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor(calibratedRed: 1, green: 0.969, blue: 0.98, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(transparentCode, in: CGRect(x: 0, y: 0, width: width, height: height))
        let compositedCode = try #require(context.makeImage())

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: compositedCode).perform([request])
        let decoded = request.results?.compactMap(\.payloadStringValue)
        #expect(decoded == [url.absoluteString])
    }
}
