nonisolated struct NameplatePaletteColors: Equatable {
    let light: UInt32
    let dark: UInt32
}

nonisolated enum NameplatePresentationPolicy {
    static func opacity(isHovered: Bool) -> Double {
        isHovered ? 0.8 : 0.5
    }

    static func colors(for palette: String) -> NameplatePaletteColors? {
        switch palette {
        case "crimson": .init(light: 0xE7040F, dark: 0x900007)
        case "berry": .init(light: 0xB11FCF, dark: 0x893A99)
        case "sky": .init(light: 0x56CCFF, dark: 0x0080B7)
        case "teal": .init(light: 0x7DEED7, dark: 0x086460)
        case "forest": .init(light: 0x6AA624, dark: 0x2D5401)
        case "bubble_gum": .init(light: 0xF957B3, dark: 0xDC3E97)
        case "violet": .init(light: 0x972FED, dark: 0x730BC8)
        case "cobalt": .init(light: 0x4278FF, dark: 0x0131C2)
        case "clover": .init(light: 0x63CD5A, dark: 0x047B20)
        case "lemon": .init(light: 0xFED400, dark: 0xF6CD12)
        case "white": .init(light: 0xFFFFFF, dark: 0xFFFFFF)
        default: nil
        }
    }
}
