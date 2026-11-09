@testable import SakuraCordModels
import Testing

/// Discord rejects an application whose answer passes the input limit, so typing or pasting must stop there.
@Test func `answers stop at Discord's UTF-16 limit and keep existing text`() {
    let field = GuildJoinApplicationField(kind: .shortAnswer, label: "Why?", isRequired: true)
    let full = String(repeating: "a", count: 150)
    // A paste into an empty answer keeps what fits.
    #expect(field.limited(String(repeating: "b", count: 170), replacing: "") == String(repeating: "b", count: 150))
    // An emoji is two UTF-16 units and is dropped whole rather than split.
    #expect(field.limited(String(repeating: "c", count: 149) + "😀", replacing: "").utf16.count == 149)
    // Typing into the middle of a full answer leaves the answer as it was.
    #expect(field.limited("aaa" + "X" + String(repeating: "a", count: 147), replacing: full) == full)
    // Pasting decomposed text over its composed twin is new text, not the existing answer.
    let composed = String(repeating: "\u{E9}", count: 150)
    #expect(field.limited(String(repeating: "e\u{301}", count: 150), replacing: composed).utf16.count <= 150)
    // A combining mark typed after a full answer's last letter is dropped; the letter stays.
    let letters = String(repeating: "a", count: 149) + "e"
    #expect(field.limited(letters + "\u{301}", replacing: letters) == letters)
}
