import Foundation

enum OrdinaryLyricParser {
    static func parse(_ response: LyricResponse, removeQRCInformation: Bool = true) -> [LyricLine] {
        if let qrc = response.qrc, !qrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parseQRC(qrc)
            let lines = removeQRCInformation ? removeInformationLines(parsed) : parsed
            if !lines.isEmpty {
                return align(align(lines, source: response.qrctrans ?? response.lrctrans, roman: false), source: response.qrcroma, roman: true)
            }
        }
        if let lrc = response.lrc { return align(parseLRC(lrc), source: response.lrctrans, roman: false) }
        return []
    }

    private static func removeInformationLines(_ lines: [LyricLine]) -> [LyricLine] {
        guard !lines.isEmpty else { return [] }
        return Array(lines.dropFirst().drop(while: isInformationLine))
    }

    private static func isInformationLine(_ line: LyricLine) -> Bool {
        guard line.text.contains(":") || line.text.contains("："),
              let duration = line.words.first.map({ $0.endTime - $0.startTime }) else { return false }
        return line.words.allSatisfy { $0.endTime - $0.startTime == duration }
    }

    private static func parseLRC(_ source: String) -> [LyricLine] {
        let pattern = try! NSRegularExpression(pattern: #"^\[(\d+):(\d+)(?:\.(\d+))?\](.*)$"#)
        var result: [LyricLine] = source.split(whereSeparator: \.isNewline).enumerated().compactMap { index, raw in
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = line as NSString
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let minute = Int64(ns.substring(with: match.range(at: 1))) ?? 0
            let second = Int64(ns.substring(with: match.range(at: 2))) ?? 0
            let fraction = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
            let milliseconds = Int64(String((fraction + "000").prefix(3))) ?? 0
            let start = minute * 60_000 + second * 1_000 + milliseconds
            let text = decode(ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty, !text.contains("纯音乐，请您欣赏") else { return nil }
            return LyricLine(id: "lrc-\(index)-\(start)", words: [.init(startTime: start, endTime: start + 3_000, word: text)], startTime: start, endTime: start + 3_000)
        }
        guard result.count > 1 else { return result }
        for index in 0..<(result.count - 1) {
            result[index].endTime = result[index + 1].startTime
            for wordIndex in result[index].words.indices { result[index].words[wordIndex].endTime = result[index + 1].startTime }
        }
        return result
    }

    private static func parseQRC(_ source: String) -> [LyricLine] {
        let linePattern = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let wordPattern = try! NSRegularExpression(pattern: #"([^{}()]*?)[({](\d+),(\d+)[})]"#)
        return source.split(whereSeparator: \.isNewline).enumerated().compactMap { index, raw in
            let line = String(raw)
            let ns = line as NSString
            guard let lineMatch = linePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let start = Int64(ns.substring(with: lineMatch.range(at: 1))) ?? 0
            let duration = Int64(ns.substring(with: lineMatch.range(at: 2))) ?? 0
            let contentRange = NSRange(location: lineMatch.range.length, length: ns.length - lineMatch.range.length)
            let words = wordPattern.matches(in: line, range: contentRange).compactMap { match -> LyricWord? in
                let text = decode(ns.substring(with: match.range(at: 1)))
                guard !text.isEmpty else { return nil }
                let wordStart = Int64(ns.substring(with: match.range(at: 2))) ?? start
                let wordDuration = Int64(ns.substring(with: match.range(at: 3))) ?? 0
                return .init(startTime: wordStart, endTime: wordStart + wordDuration, word: text)
            }
            let fallback = decode(ns.substring(with: contentRange).trimmingCharacters(in: .whitespaces))
            return LyricLine(
                id: "qrc-\(index)-\(start)",
                words: words.isEmpty ? [.init(startTime: start, endTime: start + duration, word: fallback)] : words,
                startTime: start,
                endTime: start + duration
            )
        }
    }

    private static func align(_ base: [LyricLine], source: String?, roman: Bool) -> [LyricLine] {
        guard let source, !source.isEmpty else { return base }
        let sublines = parseLRC(source)
        return base.map { line in
            guard let text = sublines.first(where: { abs($0.startTime - line.startTime) < 150 })?.text,
                  !text.isEmpty, text != "//" else { return line }
            var result = line
            if roman { result.romanLyric = text } else { result.translatedLyric = text }
            return result
        }
    }

    private static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
