@testable import DiscordProtocol
import Foundation
import Testing

@Test func `nameplates prefer streaming video over eager animated images`() throws {
    let data = Data(
        #"""
        {
          "id":"1","username":"member",
          "collectibles":{"nameplate":{
            "asset":"nameplates/cityscape","label":"Cityscape","palette":"violet",
            "assets":{
              "static_image_url":"https://cdn.example/static.png",
              "animated_image_url":"https://cdn.example/animated.png",
              "video_url":"https://cdn.example/animated.webm"
            }
          }}
        }
        """#.utf8
    )

    let user = try JSONDecoder().decode(UserDTO.self, from: data).domain()

    #expect(user.nameplate?.staticURL?.absoluteString == "https://cdn.example/static.png")
    #expect(user.nameplate?.animatedURL?.absoluteString == "https://cdn.example/animated.webm")
    #expect(user.nameplate?.label == "Cityscape")
    #expect(user.nameplate?.palette == "violet")
}

@Test func `nameplates retain animated image and derived WebM fallbacks`() throws {
    let animatedImageData = Data(
        #"""
        {
          "id":"1","username":"member",
          "collectibles":{"nameplate":{
            "asset":"nameplates/cityscape",
            "assets":{"animated_image_url":"https://cdn.example/animated.png"}
          }}
        }
        """#.utf8
    )
    let derivedData = Data(
        #"""
        {
          "id":"2","username":"member",
          "collectibles":{"nameplate":{"asset":"nameplates/cosmic-storm"}}
        }
        """#.utf8
    )

    let animatedImageUser = try JSONDecoder().decode(UserDTO.self, from: animatedImageData).domain()
    let derivedUser = try JSONDecoder().decode(UserDTO.self, from: derivedData).domain()

    #expect(animatedImageUser.nameplate?.animatedURL?.absoluteString == "https://cdn.example/animated.png")
    #expect(
        derivedUser.nameplate?.animatedURL?.absoluteString
            == "https://cdn.discordapp.com/assets/collectibles/nameplates/cosmic-storm/asset.webm"
    )
}
