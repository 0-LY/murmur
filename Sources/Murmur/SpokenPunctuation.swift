import Foundation

enum SpokenSymbol: Equatable {
    case question, exclaim, colon, semicolon, comma, period, dash, hyphen, ellipsis
    case quoteOpen(ukrainian: Bool), quoteClose(ukrainian: Bool), quoteToggle
    case bracketOpen, bracketClose, newline, paragraph

    var attachesLeft: Bool {
        switch self {
        case .question, .exclaim, .colon, .semicolon, .comma, .period, .ellipsis, .bracketClose, .quoteClose: true
        default: false
        }
    }

    var opens: Bool {
        switch self {
        case .bracketOpen, .quoteOpen: true
        default: false
        }
    }

    var endsSentence: Bool {
        switch self {
        case .question, .exclaim, .period, .newline, .paragraph: true
        default: false
        }
    }

    var isBreak: Bool { self == .newline || self == .paragraph }

    var replacesEnginePunctuation: Bool {
        switch self {
        case .question, .exclaim, .colon, .semicolon, .comma, .period, .ellipsis: true
        default: false
        }
    }
}

struct SpokenCommand {
    let words: [String]
    let symbol: SpokenSymbol
    let onlyAtEnd: Bool

    init(_ words: [String], _ symbol: SpokenSymbol, onlyAtEnd: Bool = false) {
        self.words = words
        self.symbol = symbol
        self.onlyAtEnd = onlyAtEnd
    }
}

enum SpokenToken: Equatable {
    case word(String)
    case symbol(SpokenSymbol)
}

struct SpokenPiece: Equatable {
    let token: SpokenToken
    let end: Int
}

enum SpokenPunctuation {
    static let commands: [SpokenCommand] = {
        let list: [SpokenCommand] = [
            .init(["question", "mark"], .question),
            .init(["exclamation", "mark"], .exclaim),
            .init(["exclamation", "point"], .exclaim),
            .init(["colon"], .colon),
            .init(["semicolon"], .semicolon),
            .init(["semi", "colon"], .semicolon),
            .init(["comma"], .comma),
            .init(["period"], .period),
            .init(["full", "stop"], .period),
            .init(["dot"], .period, onlyAtEnd: true),
            .init(["dash"], .dash),
            .init(["hyphen"], .hyphen),
            .init(["open", "quote"], .quoteOpen(ukrainian: false)),
            .init(["close", "quote"], .quoteClose(ukrainian: false)),
            .init(["end", "quote"], .quoteClose(ukrainian: false)),
            .init(["quote"], .quoteToggle),
            .init(["open", "bracket"], .bracketOpen),
            .init(["open", "parenthesis"], .bracketOpen),
            .init(["open", "paren"], .bracketOpen),
            .init(["close", "bracket"], .bracketClose),
            .init(["close", "parenthesis"], .bracketClose),
            .init(["close", "paren"], .bracketClose),
            .init(["new", "line"], .newline),
            .init(["newline"], .newline),
            .init(["new", "paragraph"], .paragraph),
            .init(["ellipsis"], .ellipsis),
            .init(["знак", "питання"], .question),
            .init(["знак", "оклику"], .exclaim),
            .init(["двокрапка"], .colon),
            .init(["крапка", "з", "комою"], .semicolon),
            .init(["кома"], .comma),
            .init(["крапка"], .period),
            .init(["тире"], .dash),
            .init(["дефіс"], .hyphen),
            .init(["відкрити", "лапки"], .quoteOpen(ukrainian: true)),
            .init(["закрити", "лапки"], .quoteClose(ukrainian: true)),
            .init(["відкрити", "дужку"], .bracketOpen),
            .init(["закрити", "дужку"], .bracketClose),
            .init(["новий", "рядок"], .newline),
            .init(["з", "нового", "рядка"], .newline),
            .init(["новий", "абзац"], .paragraph),
            .init(["три", "крапки"], .ellipsis),
        ]
        return list.sorted { $0.words.count > $1.words.count }
    }()

    static let maxWords = commands.map(\.words.count).max() ?? 1

    static let startWords: Set<String> = Set(commands.map { $0.words[0] })

    static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their",
        "one", "another", "each", "every", "no", "any", "some", "which", "what", "whose",
        "цей", "ця", "ці", "той", "та", "ті", "мій", "моя", "моє", "мої", "твій", "твоя", "твоє",
        "його", "її", "їхній", "їхня", "один", "одна", "одне", "кожен", "кожна", "якийсь", "якась",
        "яка", "який", "яке", "наш", "наша", "ваш", "ваша",
    ]

    static let connectors: Set<String> = [
        "of", "in", "on", "at", "for", "is", "was", "are", "were", "between", "inside", "after", "before",
        "means", "goes", "sign", "symbol", "key", "button", "character",
        "в", "у", "на", "між", "після", "перед", "це", "є", "був", "була", "було", "означає", "стоїть", "ставиться",
        "ставимо", "треба", "потрібна", "потрібно",
    ]

    static func key(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func apply(_ text: String) -> String {
        let words = LiveWords.split(text)
        guard words.contains(where: { startWords.contains(key($0)) }) else { return text }
        return render(parse(words, atEnd: true).map(\.token))
    }

    static func parse(_ words: [String], atEnd: Bool) -> [SpokenPiece] {
        let keys = words.map(key)
        var out: [SpokenPiece] = []
        var i = 0
        while i < words.count {
            if let cmd = match(keys, at: i, atEnd: atEnd) {
                out.append(SpokenPiece(token: .symbol(cmd.symbol), end: i + cmd.words.count))
                i += cmd.words.count
            } else {
                out.append(SpokenPiece(token: .word(words[i]), end: i + 1))
                i += 1
            }
        }
        return out
    }

    static func match(_ keys: [String], at i: Int, atEnd: Bool) -> SpokenCommand? {
        guard startWords.contains(keys[i]) else { return nil }
        for cmd in commands {
            let n = cmd.words.count
            guard i + n <= keys.count, Array(keys[i..<(i + n)]) == cmd.words else { continue }
            let last = i + n == keys.count
            if cmd.onlyAtEnd {
                let nextIsBreak = !last && match(keys, at: i + n, atEnd: atEnd)?.symbol.isBreak == true
                if !(last && atEnd) && !nextIsBreak { continue }
            }
            if i > 0, !cmd.symbol.isBreak, determiners.contains(keys[i - 1]) { continue }
            if !last, connectors.contains(keys[i + n]) { continue }
            return cmd
        }
        return nil
    }

    static func render(_ tokens: [SpokenToken]) -> String {
        var out = ""
        var prev: SpokenToken?
        var capNext = false
        var quoteOpen = false
        for token in tokens {
            switch token {
            case .word(var w):
                if let p = prev { out += separator(after: p, before: token) }
                if capNext, let f = w.first, f.isLowercase { w = f.uppercased() + w.dropFirst() }
                capNext = false
                out += w
            case .symbol(let raw):
                var s = raw
                if s == .quoteToggle { s = quoteOpen ? .quoteClose(ukrainian: false) : .quoteOpen(ukrainian: false) }
                if case .quoteOpen = s { quoteOpen = true }
                if case .quoteClose = s { quoteOpen = false }
                if s.replacesEnginePunctuation || s.isBreak, case .word? = prev {
                    while let last = out.last, ",.;:".contains(last) { out.removeLast() }
                }
                if s.isBreak { while out.last == " " { out.removeLast() } }
                if let p = prev { out += separator(after: p, before: .symbol(s)) }
                out += text(s)
                if s.endsSentence { capNext = true }
                prev = .symbol(s)
                continue
            }
            prev = token
        }
        return out
    }

    static func separator(after p: SpokenToken, before t: SpokenToken) -> String {
        if case .symbol(let s) = t {
            if s.attachesLeft || s.isBreak || s == .hyphen { return "" }
            if s == .dash { return " " }
        }
        if case .symbol(let ps) = p {
            if ps.opens || ps.isBreak || ps == .hyphen { return "" }
        }
        return " "
    }

    static func text(_ s: SpokenSymbol) -> String {
        switch s {
        case .question: "?"
        case .exclaim: "!"
        case .colon: ":"
        case .semicolon: ";"
        case .comma: ","
        case .period: "."
        case .dash: "—"
        case .hyphen: "-"
        case .ellipsis: "…"
        case .quoteOpen(let uk): uk ? "«" : "“"
        case .quoteClose(let uk): uk ? "»" : "”"
        case .quoteToggle: "\""
        case .bracketOpen: "("
        case .bracketClose: ")"
        case .newline: "\n"
        case .paragraph: "\n\n"
        }
    }

    static func symbolsKept(input: String, output: String) -> Bool {
        let marks: [Character] = ["?", "!", ":", ";", "(", ")", "“", "”", "«", "»", "—", "…", "\n"]
        for m in marks {
            let a = input.filter { $0 == m }.count
            guard a > 0 else { continue }
            if output.filter({ $0 == m }).count < a { return false }
        }
        return true
    }

    static func trailingBreaks(_ text: String) -> String {
        String(text.reversed().prefix { $0 == "\n" })
    }
}

struct LivePunctuator {
    private(set) var emitted = ""

    static func safeCount(_ words: [String]) -> Int {
        let n = words.count
        guard n > 0 else { return 0 }
        var change = n - 1
        let low = max(0, n - SpokenPunctuation.maxWords - 1)
        for j in stride(from: n - 1, through: low, by: -1) where SpokenPunctuation.startWords.contains(SpokenPunctuation.key(words[j])) {
            change = min(change, j)
        }
        return max(0, change - 1)
    }

    mutating func feed(_ words: [String]) -> String {
        let safe = Self.safeCount(words)
        guard safe > 0 else { return "" }
        let pieces = SpokenPunctuation.parse(words, atEnd: false).filter { $0.end <= safe }
        return emit(SpokenPunctuation.render(pieces.map(\.token)))
    }

    mutating func finish(_ words: [String]) -> String {
        emit(SpokenPunctuation.render(SpokenPunctuation.parse(words, atEnd: true).map(\.token)))
    }

    private mutating func emit(_ full: String) -> String {
        guard full.count > emitted.count else { return "" }
        let piece = String(full.dropFirst(emitted.count))
        emitted += piece
        return piece
    }
}
