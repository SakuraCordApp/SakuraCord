@testable import DiscordProtocol
import Foundation
import Testing

@Test func `nameplates use current first party sku asset selection`() throws {
    let data = Data(
        #"""
        {
          "id":"1","username":"member",
          "collectibles":{"nameplate":{
            "sku_id":"123456789012345678",
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

    #expect(
        user.nameplate?.staticURL?.absoluteString
            == "https://cdn.discordapp.com/media/v1/collectibles-shop/123456789012345678/static"
    )
    #expect(
        user.nameplate?.animatedURL?.absoluteString
            == "https://cdn.discordapp.com/media/v1/collectibles-shop/123456789012345678/animated"
    )
    #expect(user.nameplate?.label == "Cityscape")
    #expect(user.nameplate?.palette == "violet")
}

@Test func `numeric nameplate sku preserves its exact asset identifier`() throws {
    let data = Data(
        #"{"id":"1","username":"member","collectibles":{"nameplate":{"sku_id":123456789012345678}}}"#.utf8
    )

    let user = try JSONDecoder().decode(UserDTO.self, from: data).domain()

    #expect(
        user.nameplate?.staticURL?.absoluteString
            == "https://cdn.discordapp.com/media/v1/collectibles-shop/123456789012345678/static"
    )
}

@Test func `nameplates retain animated image and derived APNG fallbacks`() throws {
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

    #expect(
        animatedImageUser.nameplate?.animatedURL?.absoluteString
            == "https://cdn.example/animated.png"
    )
    #expect(
        derivedUser.nameplate?.animatedURL?.absoluteString
            == "https://cdn.discordapp.com/assets/collectibles/nameplates/cosmic-storm/img.png"
    )
}
