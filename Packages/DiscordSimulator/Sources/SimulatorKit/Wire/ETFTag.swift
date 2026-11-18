import Foundation

/// Erlang External Term Format tags (https://www.erlang.org/doc/apps/erts/erl_ext_dist.html).
/// `name` is the spelling the captured shapes use in `etf` and `ketf`.
enum ETFTag: UInt8 {
    static let version: UInt8 = 131

    case newFloat = 70
    case smallInteger = 97
    case integer = 98
    case float = 99
    case atom = 100
    case smallTuple = 104
    case largeTuple = 105
    case `nil` = 106
    case string = 107
    case list = 108
    case binary = 109
    case smallBig = 110
    case largeBig = 111
    case smallAtom = 115
    case map = 116
    case atomUTF8 = 118
    case smallAtomUTF8 = 119

    var name: String {
        switch self {
        case .newFloat: "new_float"
        case .smallInteger: "small_int"
        case .integer: "integer"
        case .float: "float"
        case .atom: "atom"
        case .smallTuple: "small_tuple"
        case .largeTuple: "large_tuple"
        case .nil: "nil"
        case .string: "string"
        case .list: "list"
        case .binary: "binary"
        case .smallBig: "small_big"
        case .largeBig: "large_big"
        case .smallAtom: "small_atom"
        case .map: "map"
        case .atomUTF8: "atom_utf8"
        case .smallAtomUTF8: "small_atom_utf8"
        }
    }
}

/// A malformed client frame or a compression stream failure.
public struct WireError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
