import NaturalLanguage
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LyricWordChunk: Identifiable, Hashable {
    let id: String
    var words: [LyricWord]
    let text: String
    let displayText: String
    let characters: [String]
    let rubyText: String
    let romanText: String
    let emphasisAmount: CGFloat
    let emphasizes: Bool
    let isSingleCJKCharacter: Bool
    var breakAfter: LyricBreakOpportunity = .character
    var forcesBreakAfter = false
    var isSpace: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(id: String, words: [LyricWord], displaySuffix: String = "", displayOverride: String? = nil) {
        self.id = id
        self.words = words
        text = words.map(\.word).joined()
        isSingleCJKCharacter = text.count == 1 && isCJK(text)
        displayText = (displayOverride ?? words.map(maskedLyricWord).joined()) + displaySuffix
        characters = displayText.map(String.init)
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
    var wrappingWidth: CGFloat?
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

/// Split only words wider than a complete lyric row. Synthetic hyphens are
/// display-only; each source grapheme and its authored timing occur once.
func wrapOversizedLyricChunks(_ chunks: [LyricWordChunk], width: CGFloat, fontSize: CGFloat) -> [LyricWordChunk] {
    guard width.isFinite, width > 0, fontSize > 0 else { return chunks }
    #if os(macOS)
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    #else
    let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    #endif
    func measure(_ text: String, separateGlyphs: Bool) -> CGFloat {
        func advance(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: font]).width
        }
        // Fragments can become emphasized even when the original long word
        // was not. Reserve whichever glyph layout is wider.
        let glyphWidth = text.reduce(CGFloat.zero) { $0 + advance(String($1)) }
        return separateGlyphs ? glyphWidth : max(advance(text), glyphWidth)
    }
    func fragmentWords(_ words: [LyricWord], range: Range<Int>) -> [LyricWord] {
        var cursor = 0
        return words.compactMap { word in
            let characters = Array(word.word)
            defer { cursor += characters.count }
            let lower = max(range.lowerBound - cursor, 0)
            let upper = min(range.upperBound - cursor, characters.count)
            guard lower < upper else { return nil }
            var result = word
            result.word = String(characters[lower..<upper])
            let duration = word.endTime - word.startTime
            result.startTime = word.startTime + Int64(Double(duration) * Double(lower) / Double(characters.count))
            result.endTime = word.startTime + Int64(Double(duration) * Double(upper) / Double(characters.count))
            if lower > 0 { result.ruby = []; result.romanWord = "" }
            return result
        }
    }
    return chunks.flatMap { chunk -> [LyricWordChunk] in
        guard !chunk.isSpace, chunk.characters.count > 1,
              measure(chunk.displayText, separateGlyphs: chunk.emphasizes) > width else { return [chunk] }
        let characters = chunk.characters
        var fragments: [LyricWordChunk] = []
        var start = 0
        while start < characters.count {
            var lower = start + 1
            var upper = characters.count
            var end = start + 1 // Always consume at least one complete grapheme.
            if measure(characters[start...].joined(), separateGlyphs: chunk.emphasizes) <= width {
                // The final fragment needs no synthetic hyphen. Check it
                // before searching prefixes that reserve space for one.
                end = characters.count
                lower = upper + 1
            }
            while lower <= upper {
                let candidate = lower + (upper - lower) / 2
                let suffix = candidate < characters.count && characters[candidate - 1] != "-" ? "-" : ""
                let text = characters[start..<candidate].joined() + suffix
                if measure(text, separateGlyphs: chunk.emphasizes) <= width {
                    end = candidate
                    lower = candidate + 1
                } else { upper = candidate - 1 }
            }
            // Prefer an existing hyphen, preserving it without doubling it.
            if end < characters.count,
               let hyphen = (start..<end).last(where: { characters[$0] == "-" }) {
                end = hyphen + 1
            }
            let suffix = end < characters.count && characters[end - 1] != "-" ? "-" : ""
            var fragment = LyricWordChunk(
                id: "\(chunk.id)-wrap-\(start)", words: fragmentWords(chunk.words, range: start..<end),
                displaySuffix: suffix, displayOverride: characters[start..<end].joined()
            )
            fragment.breakAfter = end == characters.count ? chunk.breakAfter : .word
            fragment.forcesBreakAfter = end < characters.count
            fragments.append(fragment)
            start = end
        }
        return fragments
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

/// Splits a timed word into runs of whitespace and non-whitespace. Compiling
/// this per word made loading a word-timed song walk the regular expression
/// engine hundreds of times on the main thread.
private let wordSplittingExpression = try! NSRegularExpression(pattern: #"\s+|\S+"#)

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
            // Ruby belongs to the intact word, not its surrounding spaces.
            let leading = String(word.word.prefix(while: { $0.isWhitespace }))
            let trailing = String(word.word.reversed().prefix(while: { $0.isWhitespace }).reversed())
            if !leading.isEmpty {
                var atom = word
                atom.word = leading
                atom.endTime = word.startTime
                atom.ruby = []
                atom.romanWord = ""
                appendAtom(atom)
            }
            var atom = word
            atom.word = content
            appendAtom(atom)
            if !trailing.isEmpty {
                atom.word = trailing
                atom.startTime = word.endTime
                atom.endTime = word.endTime
                atom.ruby = []
                atom.romanWord = ""
                appendAtom(atom)
            }
            continue
        }
        let ns = word.word as NSString
        let matches = wordSplittingExpression.matches(in: word.word, range: NSRange(location: 0, length: ns.length))
        let parts = matches.map { ns.substring(with: $0.range) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let romans = word.romanWord.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var partIndex = 0
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
                atom.romanWord = parts.count == romans.count
                    ? romans[partIndex]
                    : (partIndex == 0 ? word.romanWord : "")
                partIndex += 1
                appendAtom(atom)
            }
        }
    }
    flush()
    return annotateLyricBreaks(result)
}

private func isCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3040...0x30FF,
             0x3130...0x318F, 0x31F0...0x31FF, 0xA960...0xA97F, 0xD7B0...0xD7FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}

/// Prepared once with the chunks; playback frames only reuse these boundaries.
enum LyricBreakOpportunity: Hashable {
    case phrase, word, character, avoid

    func penalty(width: CGFloat) -> CGFloat {
        let ratio: CGFloat = switch self {
        case .phrase: 0
        case .word: 0.04
        case .character: 0.20
        case .avoid: 4
        }
        return width * width * ratio
    }
}

private func annotateLyricBreaks(_ source: [LyricWordChunk]) -> [LyricWordChunk] {
    var chunks = source
    let text = chunks.map(\.text).joined()
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var boundaries: Set<Int> = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        boundaries.insert(range.upperBound.utf16Offset(in: text))
        return true
    }
    let opening = CharacterSet(charactersIn: "（【《「『‘“([{<")
    let closing = CharacterSet(charactersIn: "，。；：！？、）】》」』’”),.;:!?]}>…")
    var offset = 0
    var previous = ""
    for index in chunks.indices {
        offset += chunks[index].text.utf16.count
        if !chunks[index].isSpace {
            previous = chunks[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let next = chunks.dropFirst(index + 1).first(where: { !$0.isSpace })?.text ?? ""
        if previous.unicodeScalars.last.map(opening.contains) == true
            || next.unicodeScalars.first.map(closing.contains) == true {
            chunks[index].breakAfter = .avoid
        } else if previous.unicodeScalars.last.map(closing.contains) == true {
            chunks[index].breakAfter = .phrase
        } else if chunks[index].isSpace || boundaries.contains(offset) {
            chunks[index].breakAfter = .word
        }
    }
    return chunks
}

/// First minimize row count, then balance widths with linguistic break costs.
/// English syllables and ruby words remain indivisible timed chunks.
struct BalancedLyricLayout: Layout {
    var trailingAlignment: Bool
    var horizontalSpacing: CGFloat = 0
    var spaces: [Bool] = []
    var singleCharacterWords: [Bool] = []
    var breakOpportunities: [LyricBreakOpportunity] = []
    var forcedBreaks: [Bool] = []

    struct Cache {
        var sizes: [CGSize] = []
        var rows: [Range<Int>] = []
        var width: CGFloat?
        var spacing: CGFloat?
        var spaces: [Bool] = []
        var singleCharacterWords: [Bool] = []
        var breakOpportunities: [LyricBreakOpportunity] = []
        var forcedBreaks: [Bool] = []

        mutating func updateSizes(_ newSizes: [CGSize]) {
            guard sizes != newSizes else { return }
            sizes = newSizes
            width = nil
        }
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.updateSizes(sizes)
    }

    func cachedRows(width: CGFloat, cache: inout Cache) -> [Range<Int>] {
        if cache.width != width || cache.spacing != horizontalSpacing
            || cache.spaces != spaces || cache.singleCharacterWords != singleCharacterWords
            || cache.breakOpportunities != breakOpportunities || cache.forcedBreaks != forcedBreaks {
            cache.rows = calculateRows(sizes: cache.sizes, width: width)
            cache.width = width
            cache.spacing = horizontalSpacing
            cache.spaces = spaces
            cache.singleCharacterWords = singleCharacterWords
            cache.breakOpportunities = breakOpportunities
            cache.forcedBreaks = forcedBreaks
        }
        return cache.rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        updateCache(&cache, subviews: subviews)
        let width = proposal.width ?? cache.sizes.reduce(0) { $0 + $1.width }
        let rows = cachedRows(width: width, cache: &cache)
        return .init(width: width, height: rows.reduce(0) { $0 + rowHeight($1, cache.sizes) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.sizes.count != subviews.count { updateCache(&cache, subviews: subviews) }
        let rows = cachedRows(width: bounds.width, cache: &cache)
        var y = bounds.minY
        var cursor = 0
        for range in rows {
            // Only discarded boundary spaces are placed at zero size;
            // internal spaces keep their normal width within the row.
            for index in cursor..<range.lowerBound {
                subviews[index].place(at: bounds.origin, proposal: .zero)
            }
            cursor = range.upperBound
            let height = rowHeight(range, cache.sizes)
            let rowWidth = range.reduce(0) { $0 + lyricConstrainedChunkSize(cache.sizes[$1], width: bounds.width).width }
                + CGFloat(max(0, range.count - 1)) * horizontalSpacing
            var x = trailingAlignment ? bounds.maxX - rowWidth : bounds.minX
            for index in range {
                let size = lyricConstrainedChunkSize(cache.sizes[index], width: bounds.width)
                subviews[index].place(at: .init(x: x, y: y + height - size.height), proposal: .init(size))
                x += size.width + horizontalSpacing
            }
            y += height
        }
        for index in cursor..<subviews.count {
            subviews[index].place(at: bounds.origin, proposal: .zero)
        }
    }

    private func rowHeight(_ range: Range<Int>, _ sizes: [CGSize]) -> CGFloat {
        range.reduce(CGFloat.zero) { max($0, sizes[$1].height) }
    }

    private func isSpace(_ index: Int) -> Bool {
        spaces.indices.contains(index) && spaces[index]
    }

    private func calculateRows(sizes: [CGSize], width proposedWidth: CGFloat) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        let count = sizes.count
        let width = proposedWidth.isFinite ? max(1, proposedWidth) : sizes.reduce(0) { $0 + $1.width }
        var prefix = Array(repeating: CGFloat.zero, count: count + 1)
        for index in sizes.indices { prefix[index + 1] = prefix[index] + sizes[index].width }
        func skipSpaces(_ start: Int) -> Int {
            var index = start
            while index < count && isSpace(index) { index += 1 }
            return index
        }
        func visibleEnd(_ end: Int, start: Int) -> Int {
            var index = end
            while index > start && isSpace(index - 1) { index -= 1 }
            return index
        }
        let first = skipSpaces(0)
        let last = visibleEnd(count, start: first)
        guard first < last else { return [] }
        let fullWidth = prefix[last] - prefix[first] + CGFloat(last - first - 1) * horizontalSpacing
        if fullWidth <= width && !(first..<(last - 1)).contains(where: { forcedBreaks.indices.contains($0) && forcedBreaks[$0] }) {
            return [first..<last]
        }
        var costs = Array(repeating: CGFloat.infinity, count: count + 1)
        var rowCounts = Array(repeating: Int.max, count: count + 1)
        var next = Array(repeating: count, count: count + 1)
        costs[count] = 0
        rowCounts[count] = 0
        for start in stride(from: count - 1, through: 0, by: -1) {
            if isSpace(start) {
                costs[start] = costs[start + 1]
                rowCounts[start] = rowCounts[start + 1]
                next[start] = next[start + 1]
                continue
            }
            for end in (start + 1)...count {
                if end > start + 1, forcedBreaks.indices.contains(end - 2), forcedBreaks[end - 2] { break }
                if isSpace(end - 1) { continue }
                let lineWidth = prefix[end] - prefix[start] + CGFloat(end - start - 1) * horizontalSpacing
                if lineWidth > width && end > start + 1 { break }
                let following = skipSpaces(end)
                let overflow = max(0, lineWidth - width)
                let slack = max(0, width - lineWidth)
                let boundary = following > end ? following - 1 : end - 1
                let opportunity = breakOpportunities.indices.contains(boundary) ? breakOpportunities[boundary] : .character
                let penalty = following == count ? 0 : opportunity.penalty(width: width)
                let cost = slack * slack + overflow * overflow * 1_000 + penalty + costs[following]
                let rows = 1 + rowCounts[following]
                if rows < rowCounts[start] || (rows == rowCounts[start] && cost < costs[start]) {
                    rowCounts[start] = rows
                    costs[start] = cost
                    next[start] = following
                }
            }
        }
        var rows: [Range<Int>] = []
        var cursor = skipSpaces(0)
        while cursor < count {
            let following = max(cursor + 1, next[cursor])
            let end = visibleEnd(following, start: cursor)
            rows.append(cursor..<end)
            cursor = skipSpaces(following)
        }
        return preferNearbySpaces(rows: rows, prefixWidths: prefix, width: width)
    }

    /// Snap an existing CJK character break to the nearest space within two
    /// graphemes. Both adjoining rows must still fit; timed chunks stay intact.
    private func preferNearbySpaces(rows original: [Range<Int>], prefixWidths: [CGFloat], width: CGFloat) -> [Range<Int>] {
        guard original.count > 1 else { return original }
        var rows = original
        func isSingleCharacter(_ index: Int) -> Bool {
            singleCharacterWords.indices.contains(index) && singleCharacterWords[index]
        }
        func rowWidth(_ range: Range<Int>) -> CGFloat {
            prefixWidths[range.upperBound] - prefixWidths[range.lowerBound]
                + CGFloat(max(0, range.count - 1)) * horizontalSpacing
        }
        for index in 0..<(rows.count - 1) {
            let left = rows[index]
            if forcedBreaks.indices.contains(left.upperBound - 1), forcedBreaks[left.upperBound - 1] { continue }
            let right = rows[index + 1]
            // A break already on whitespace needs no adjustment.
            guard left.upperBound == right.lowerBound,
                  isSingleCharacter(left.upperBound - 1),
                  isSingleCharacter(right.lowerBound) else { continue }
            let boundary = left.upperBound
            var candidates: [(space: Range<Int>, distance: Int)] = []
            for direction in [-1, 1] {
                var cursor = direction < 0 ? boundary - 1 : boundary
                var distance = 0
                while cursor >= left.lowerBound && cursor < right.upperBound {
                    if isSpace(cursor) {
                        var start = cursor
                        var end = cursor + 1
                        while start > left.lowerBound && isSpace(start - 1) { start -= 1 }
                        while end < right.upperBound && isSpace(end) { end += 1 }
                        candidates.append((start..<end, distance))
                        break
                    }
                    guard distance < 2, isSingleCharacter(cursor) else { break }
                    distance += 1
                    cursor += direction
                }
            }
            var best: (left: Range<Int>, right: Range<Int>, distance: Int, imbalance: CGFloat)?
            for candidate in candidates {
                guard candidate.space.lowerBound > left.lowerBound,
                      candidate.space.upperBound < right.upperBound else { continue }
                let opportunityIndex = candidate.space.upperBound - 1
                if breakOpportunities.indices.contains(opportunityIndex),
                   breakOpportunities[opportunityIndex] == .avoid { continue }
                let newLeft = left.lowerBound..<candidate.space.lowerBound
                let newRight = candidate.space.upperBound..<right.upperBound
                let leftWidth = rowWidth(newLeft)
                let rightWidth = rowWidth(newRight)
                guard leftWidth <= width, rightWidth <= width else { continue }
                let imbalance = abs(leftWidth - rightWidth)
                if best == nil || candidate.distance < best!.distance
                    || (candidate.distance == best!.distance && imbalance < best!.imbalance) {
                    best = (newLeft, newRight, candidate.distance, imbalance)
                }
            }
            if let best {
                rows[index] = best.left
                rows[index + 1] = best.right
            }
        }
        return rows
    }
}

/// Keep each prepared word fragment inside its row, including narrow layouts
/// where even a single grapheme is wider than the available space.
func lyricConstrainedChunkSize(_ ideal: CGSize, width: CGFloat) -> CGSize {
    CGSize(width: width.isFinite ? min(ideal.width, max(0, width)) : ideal.width, height: ideal.height)
}

/// Room for the three-radius shadow, character scale, and emphasis wave.
/// This is drawing bleed, not spacing between words or lyric rows.
func lyricEffectBleed(fontSize: CGFloat, characterCount: Int) -> CGFloat {
    max(0, fontSize) * (0.9 + 0.009 * CGFloat(max(0, characterCount - 1)))
}

/// Keep the progress head over the original glyph width even though the mask
/// surface is larger to accommodate glow and upward-moving characters.
func lyricProgressMaskStops(
    progress: CGFloat,
    surfaceWidth: CGFloat,
    contentInset: CGFloat,
    fadeWidth: CGFloat
) -> (opaqueEnd: CGFloat, clearStart: CGFloat) {
    let surface = max(surfaceWidth, 1)
    let width = max(1, surface - contentInset * 2)
    let band = min(width * 0.5, max(0, fadeWidth))
    let head = contentInset + min(max(progress, 0), 1) * (width + band) - band / 2
    return (
        min(max((head - band / 2) / surface, 0), 1),
        min(max((head + band / 2) / surface, 0), 1)
    )
}
