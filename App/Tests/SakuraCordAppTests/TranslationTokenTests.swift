@testable import SakuraCord
import Foundation
import Testing

@Test(arguments: [
    "Hoi <@123> en <@!123> en <@&456> in <#789> @everyone @here",
    "Hoi <:sakura:123> <a:sakura:456> <t:123:R> </greet wave:456>",
    "Hoi [🌸](https://cdn.discordapp.com/emojis/123.png?size=48) https://example.com/a?q=hoi",
    "Hoi [label](mailto:test@example.com) en `let geheim = 1`\n```swift\nlet secret = true\n```",
    "**Goedemorgen** ||dit is verborgen||\n> سلام 👩🏽‍💻 こんにちは\n- Nederlands",
    "Tekst \u{E000}0\u{E001} tekst <@123> <@123> \u{F0000} placeholder-0",
    "Hoi ```onafgemaakte code\nlet geheim = 1",
    "Hoi \\*letterlijk\\* en [link](https://example.com/a_(b))",
])
func `translation syntax and repeated tokens round trip without model placeholders`(_ source: String) throws {
    let plan = TranslationTokenProtector(source)
    #expect(plan.hasTranslatableText)
    #expect(try plan.restore(plan.slots) == source)
    for slot in plan.slots {
        #expect(!slot.text.contains("<@"))
        #expect(!slot.text.contains("https://"))
        #expect(!slot.text.contains("`"))
        #expect(!slot.text.contains("||"))
        #expect(!slot.text.unicodeScalars.contains(where: { $0.properties.generalCategory == .privateUse }))
    }
}

@Test func `translation restoration rejects missing duplicated unknown and corrupted slots`() throws {
    let plan = TranslationTokenProtector("Hallo <@123> wereld ||geheim||")
    let first = try #require(plan.slots.first)
    #expect(throws: LocalTranslationError.protectedTokenChanged) { try plan.restore([]) }
    #expect(throws: LocalTranslationError.protectedTokenChanged) { try plan.restore(plan.slots + [first]) }
    var duplicate = plan.slots
    duplicate[1] = first
    #expect(throws: LocalTranslationError.protectedTokenChanged) { try plan.restore(duplicate) }
    var unknown = plan.slots
    unknown[0] = .init(index: 999, text: "hello")
    #expect(throws: LocalTranslationError.protectedTokenChanged) { try plan.restore(unknown) }
    for corrupted in ["<@999>", "||exposed||", "\u{E000}0\u{E001}", "https://evil.example", "`code`", "", "line\nbreak"] {
        var changed = plan.slots
        changed[0] = .init(index: first.index, text: corrupted)
        #expect(throws: LocalTranslationError.protectedTokenChanged) { try plan.restore(changed) }
    }
    let reversed = Array(plan.slots.reversed())
    #expect(try plan.restore(reversed) == plan.original)
}

@Test func `translation reconstructs translated prose inside original spoiler and code boundaries`() throws {
    let plan = TranslationTokenProtector("Hoi <@1> ||geheim|| `code`\nDag")
    let outputs = ["Hello", "secret", "Bye"]
    let slots = zip(plan.slots, outputs).map { TranslationTokenProtector.Slot(index: $0.0.index, text: $0.1) }
    #expect(try plan.restore(slots) == "Hello <@1> ||secret|| `code`\nBye")
    #expect(!TranslationTokenProtector("<@1> `code` https://example.com 👋").hasTranslatableText)
    #expect(TranslationTokenProtector("Hi").hasTranslatableText)
}
