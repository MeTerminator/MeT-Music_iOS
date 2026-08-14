import SwiftUI

struct LyricWordChunk: Identifiable, Hashable {
    let id: String
    var words: [LyricWord]
    let text: String
    let displayText: String
    let rubyText: String
    let romanText: String
    let emphasisAmount: CGFloat
    let emphasizes: Bool
    var isSpace: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(id: String, words: [LyricWord]) {
        self.id = id
        self.words = words
        text = words.map(\.word).joined()
        displayText = words.map(maskedLyricWord).joined()
        rubyText = words.flatMap(\.ruby).map(\.word).joined()
        romanText = words.map(\.romanWord).joined()
        let duration = max(1, (words.last?.endTime ?? 0) - (words.first?.startTime ?? 0))
        var amount = CGFloat(duration) / 2_000
        amount = amount > 1 ? sqrt(amount) : pow(amount, 3)
        emphasisAmount = min(1.2, amount * 0.6)
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        emphasizes = duration >= 1_000
            && (!trimmed.unicodeScalars.allSatisfy(\.properties.isAlphabetic) || (2...7).contains(trimmed.count))
    }
}

private func maskedLyricWord(_ word: LyricWord) -> String {
    guard word.isObscene else { return word.word }
    guard word.word.count > 2 else { return String(repeating: "*", count: word.word.count) }
    return String(word.word.prefix(1))
        + String(repeating: "*", count: word.word.count - 2)
        + String(word.word.suffix(1))
}

struct LyricGroup: Identifiable, Hashable {
    var main: LyricLine
    var background: LyricLine?
    var mainChunks: [LyricWordChunk]
    var backgroundChunks: [LyricWordChunk]
    var renderBounds: LyricRenderBounds
    var id: String { main.id }

    init(main: LyricLine, background: LyricLine? = nil) {
        self.main = main
        self.background = background
        mainChunks = chunkLyricWords(main.words)
        backgroundChunks = background.map { chunkLyricWords($0.words) } ?? []
        renderBounds = lyricGroupRenderBounds(main: main, background: background)
    }

    mutating func attachBackground(_ line: LyricLine) {
        background = line
        backgroundChunks = chunkLyricWords(line.words)
        renderBounds = lyricGroupRenderBounds(main: main, background: line)
    }
}

func groupLyricLines(_ lines: [LyricLine]) -> [LyricGroup] {
    var groups: [LyricGroup] = []
    for line in lines {
        if line.isBackground, !groups.isEmpty, groups[groups.count - 1].background == nil {
            groups[groups.count - 1].attachBackground(line)
        } else {
            groups.append(.init(main: line))
        }
    }
    return groups
}

func chunkLyricWords(_ words: [LyricWord]) -> [LyricWordChunk] {
    var result: [LyricWordChunk] = []
    var group: [LyricWord] = []
    var serial = 0
    func flush() {
        guard !group.isEmpty else { return }
        result.append(.init(id: "chunk-\(serial)", words: group))
        serial += 1
        group.removeAll(keepingCapacity: true)
    }
    func appendAtom(_ atom: LyricWord) {
        let mergeable = !atom.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && atom.ruby.isEmpty && !isCJK(atom.word)
        if mergeable { group.append(atom) }
        else {
            flush()
            result.append(.init(id: "chunk-\(serial)", words: [atom]))
            serial += 1
        }
    }

    for word in words {
        let content = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { appendAtom(word); continue }
        if !word.ruby.isEmpty {
            appendAtom(word)
            continue
        }
        let ns = word.word as NSString
        let expression = try! NSRegularExpression(pattern: #"\s+|\S+"#)
        let matches = expression.matches(in: word.word, range: NSRange(location: 0, length: ns.length))
        let nonSpaceLength = max(1, word.word.filter { !$0.isWhitespace }.count)
        let duration = word.endTime - word.startTime
        var offset = 0
        for match in matches {
            let part = ns.substring(with: match.range)
            if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let time = word.startTime + Int64(Double(duration) * Double(offset) / Double(nonSpaceLength))
                var atom = word
                atom.word = part
                atom.startTime = time
                atom.endTime = time
                atom.romanWord = ""
                appendAtom(atom)
            } else if isCJK(part), part.count > 1, word.romanWord.isEmpty {
                for character in part {
                    let start = word.startTime + Int64(Double(duration) * Double(offset) / Double(nonSpaceLength))
                    offset += 1
                    var atom = word
                    atom.word = String(character)
                    atom.startTime = start
                    atom.endTime = word.startTime + Int64(Double(duration) * Double(offset) / Double(nonSpaceLength))
                    appendAtom(atom)
                }
            } else {
                let start = word.startTime + Int64(Double(duration) * Double(offset) / Double(nonSpaceLength))
                offset += part.filter { !$0.isWhitespace }.count
                var atom = word
                atom.word = part
                atom.startTime = start
                atom.endTime = word.startTime + Int64(Double(duration) * Double(offset) / Double(nonSpaceLength))
                appendAtom(atom)
            }
        }
    }
    flush()
    return result
}

private func isCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x2E80...0x2FDF, 0x3040...0x30FF, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}

/// Balanced dynamic-programming line breaking. Each subview is an indivisible
/// timed-word chunk, so a single English word can never split across rows.
struct BalancedLyricLayout: Layout {
    var trailingAlignment: Bool
    var horizontalSpacing: CGFloat = 0

    struct Cache { var sizes: [CGSize] = [] }

    func makeCache(subviews: Subviews) -> Cache { .init() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? cache.sizes.reduce(0) { $0 + $1.width }
        let rows = calculateRows(sizes: cache.sizes, width: width)
        return .init(width: width, height: rows.reduce(0) { $0 + rowHeight($1, cache.sizes) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.sizes.count != subviews.count { cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) } }
        let rows = calculateRows(sizes: cache.sizes, width: bounds.width)
        var y = bounds.minY
        for range in rows {
            let height = rowHeight(range, cache.sizes)
            let rowWidth = range.reduce(0) { $0 + cache.sizes[$1].width } + CGFloat(max(0, range.count - 1)) * horizontalSpacing
            var x = trailingAlignment ? bounds.maxX - rowWidth : bounds.minX
            for index in range {
                let size = cache.sizes[index]
                subviews[index].place(at: .init(x: x, y: y + height - size.height), proposal: .init(size))
                x += size.width + horizontalSpacing
            }
            y += height
        }
    }

    private func rowHeight(_ range: Range<Int>, _ sizes: [CGSize]) -> CGFloat {
        range.map { sizes[$0].height }.max() ?? 0
    }

    private func calculateRows(sizes: [CGSize], width: CGFloat) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        let count = sizes.count
        var prefix = Array(repeating: CGFloat.zero, count: count + 1)
        for index in sizes.indices { prefix[index + 1] = prefix[index] + sizes[index].width }
        if prefix[count] <= width { return [0..<count] }
        var costs = Array(repeating: CGFloat.infinity, count: count + 1)
        var next = Array(repeating: -1, count: count + 1)
        costs[count] = 0
        for start in stride(from: count - 1, through: 0, by: -1) {
            for end in (start + 1)...count {
                let lineWidth = prefix[end] - prefix[start]
                if lineWidth > width && end > start + 1 { break }
                let overflow = max(0, lineWidth - width)
                let slack = max(0, width - lineWidth)
                let lineCost = overflow > 0 ? overflow * overflow * 1_000 : slack * slack
                let lastLinePenalty: CGFloat = end == count ? 0 : width * width * 0.08
                let total = lineCost + lastLinePenalty + costs[end]
                if total < costs[start] { costs[start] = total; next[start] = end }
            }
        }
        var rows: [Range<Int>] = []
        var cursor = 0
        while cursor < count {
            let end = next[cursor] > cursor ? next[cursor] : cursor + 1
            rows.append(cursor..<end)
            cursor = end
        }
        return rows
    }
}
