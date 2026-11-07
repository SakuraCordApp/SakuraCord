import Foundation

/// Discord-coloured code highlighting: JSON, and a pass for every other language.
extension DiscordMarkdown {
    static func codeRuns(
        _ source: String,
        language: String?
    ) -> [AppKitPlan.InlineRun] {
        if source.contains("\u{001B}") {
            // Discord's current renderer does not interpret ANSI SGR in this
            // fixture. The control character itself has no visible glyph,
            // while the bracketed escape payload remains literal.
            return [
                AppKitPlan.InlineRun(
                    text: source.replacingOccurrences(
                        of: "\u{001B}",
                        with: ""
                    ),
                    traits: [],
                    link: nil,
                    color: nil
                )
            ]
        }
        if language == "json" {
            return jsonRuns(source)
        }
        if let language, !plainCodeLanguages.contains(language) {
            return highlightedCodeRuns(source, lineComment: lineComment(for: language))
        }
        return [
            AppKitPlan.InlineRun(
                text: source,
                traits: [],
                link: nil,
                color: nil
            )
        ]
    }

    private static func jsonRuns(_ source: String) -> [AppKitPlan.InlineRun] {
        var output: [AppKitPlan.InlineRun] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if source[cursor] == "\"" {
                var end = source.index(after: cursor)
                var escaped = false
                while end < source.endIndex {
                    if source[end] == "\"", !escaped {
                        end = source.index(after: end)
                        break
                    }
                    escaped = source[end] == "\\" && !escaped
                    if source[end] != "\\" {
                        escaped = false
                    }
                    end = source.index(after: end)
                }
                output.append(
                    AppKitPlan.InlineRun(
                        text: String(source[cursor ..< end]),
                        traits: [],
                        link: nil,
                        color: jsonStringColor(
                            in: source,
                            after: end
                        )
                    )
                )
                cursor = end
                continue
            }
            if source[cursor].isNumber || source[cursor] == "-" {
                var end = source.index(after: cursor)
                while end < source.endIndex,
                      source[end].isNumber || ".eE+-".contains(source[end])
                {
                    end = source.index(after: end)
                }
                output.append(
                    AppKitPlan.InlineRun(
                        text: String(source[cursor ..< end]),
                        traits: [],
                        link: nil,
                        color: .jsonNumber
                    )
                )
                cursor = end
                continue
            }
            let tail = source[cursor...]
            if let keyword = ["true", "false", "null"].first(
                where: { tail.hasPrefix($0) }
            ) {
                output.append(
                    AppKitPlan.InlineRun(
                        text: keyword,
                        traits: [],
                        link: nil,
                        color: .jsonKeyword
                    )
                )
                cursor = source.index(cursor, offsetBy: keyword.count)
                continue
            }

            var end = source.index(after: cursor)
            while end < source.endIndex,
                  source[end] != "\"",
                  !source[end].isNumber,
                  !source[end...].hasPrefix("true"),
                  !source[end...].hasPrefix("false"),
                  !source[end...].hasPrefix("null")
            {
                end = source.index(after: end)
            }
            output.append(
                AppKitPlan.InlineRun(
                    text: String(source[cursor ..< end]),
                    traits: [],
                    link: nil,
                    color: nil
                )
            )
            cursor = end
        }
        return output
    }

    private static func jsonStringColor(
        in source: String,
        after stringEnd: String.Index
    ) -> AppKitPlan.SemanticColor {
        var lookahead = stringEnd
        while lookahead < source.endIndex,
              source[lookahead].isWhitespace
        {
            lookahead = source.index(after: lookahead)
        }
        return lookahead < source.endIndex && source[lookahead] == ":"
            ? .jsonKey
            : .jsonString
    }

    /// Languages Discord shows uncoloured.
    private static let plainCodeLanguages: Set<String> = [
        "txt", "text", "plaintext", "log", "md", "markdown", "mkd", "mkdown", "csv", "ansi",
    ]

    private static func lineComment(for language: String) -> String {
        switch language {
        case "py", "python", "sh", "bash", "zsh", "shell", "console", "rb", "ruby", "yml", "yaml", "toml", "r",
             "pl", "perl", "pm", "make", "makefile", "mk", "dockerfile", "docker", "conf", "cmake", "ps1",
             "powershell", "ex", "exs", "elixir", "nim", "coffee", "coffeescript", "tcl", "gdscript", "nix",
             "properties", "graphql", "gn", "crystal", "cr", "julia", "awk":
            "#"
        case "sql", "lua", "hs", "haskell", "elm", "ada", "vhdl", "pgsql", "postgres", "postgresql", "tsql":
            "--"
        case "lisp", "clj", "clojure", "scheme", "ini", "asm", "armasm", "x86asm", "nasm":
            ";"
        default:
            "//"
        }
    }

    private static let codeKeywords: Set<String> = [
        "abstract", "and", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def",
        "default", "defer", "del", "do", "done", "elif", "else", "end", "enum", "esac", "export", "extends",
        "extension", "false", "fi", "fileprivate", "final", "finally", "fn", "for", "from", "func", "function",
        "guard", "if", "impl", "implements", "import", "in", "init", "inout", "interface", "internal", "is",
        "lambda", "let", "local", "match", "mod", "module", "mut", "namespace", "new", "nil", "None", "not",
        "null", "of", "open", "operator", "or", "override", "package", "private", "protected", "protocol",
        "pub", "public", "raise", "repeat", "return", "self", "Self", "static", "struct", "super", "switch",
        "then", "this", "throw", "throws", "trait", "true", "True", "False", "try", "type", "typealias",
        "typeof", "undefined", "unless", "use", "using", "val", "var", "void", "where", "while", "with", "yield",
    ]

    /// A language-agnostic pass in Discord's code colours: comments, strings,
    /// numbers, keywords, operators, and capitalised or called names as titles.
    private static func highlightedCodeRuns(_ source: String, lineComment: String) -> [AppKitPlan.InlineRun] {
        var output: [AppKitPlan.InlineRun] = []
        // Tokens are consecutive slices of `source`, so a run of one colour
        // is cut from it once, when the colour changes.
        var runStart = source.startIndex
        var runColor: AppKitPlan.SemanticColor?
        func endRun(at end: String.Index) {
            if runStart < end {
                output.append(AppKitPlan.InlineRun(text: String(source[runStart ..< end]), traits: [], link: nil, color: runColor))
            }
            runStart = end
        }
        func append(_ token: Substring, _ color: AppKitPlan.SemanticColor?) {
            guard color != runColor else { return }
            endRun(at: token.startIndex)
            runColor = color
        }
        // A block comment's continuation lines are coloured from their own start.
        let trimmed = source.drop { $0 == " " || $0 == "\t" }
        if lineComment == "//", trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
            return [AppKitPlan.InlineRun(text: source, traits: [], link: nil, color: .codeComment)]
        }
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let character = source[cursor]
            let rest = source[cursor...]
            if rest.hasPrefix(lineComment) || (lineComment == "//" && rest.hasPrefix("/*")) {
                append(rest, .codeComment)
                break
            }
            if "\"'`".contains(character) {
                var end = source.index(after: cursor)
                while end < source.endIndex, source[end] != character {
                    if source[end] == "\\" { end = source.index(after: end) }
                    if end < source.endIndex { end = source.index(after: end) }
                }
                end = end < source.endIndex ? source.index(after: end) : end
                append(source[cursor ..< end], .codeString)
                cursor = end
                continue
            }
            if character.isLetter || character == "_" || character == "$" || character == "@" {
                var end = source.index(after: cursor)
                while end < source.endIndex, source[end].isLetter || source[end].isNumber || source[end] == "_" {
                    end = source.index(after: end)
                }
                let word = source[cursor ..< end]
                let next = source[end...].first { $0 != " " }
                let color: AppKitPlan.SemanticColor? = if codeKeywords.contains(String(word)) {
                    .codeKeyword
                } else if next == "(" || word.first?.isUppercase == true {
                    .codeTitle
                } else {
                    nil
                }
                append(word, color)
                cursor = end
                continue
            }
            if character.isNumber {
                var end = source.index(after: cursor)
                while end < source.endIndex, source[end].isHexDigit || "._xXoObB".contains(source[end]) {
                    end = source.index(after: end)
                }
                append(source[cursor ..< end], .codeNumber)
                cursor = end
                continue
            }
            let end = source.index(after: cursor)
            append(source[cursor ..< end], "=+-*/%<>!&|^~?".contains(character) ? .codeOperator : nil)
            cursor = end
        }
        endRun(at: source.endIndex)
        return output
    }
}
