import Foundation

enum LyricFormat {
    case lrc, qrc, yrc, ttml

    func transitionLeadMs(configuredMs: Int64) -> Int64 {
        self == .qrc || self == .yrc ? configuredMs : 0
    }
}

enum OrdinaryLyricParser {
    static func parse(_ response: LyricResponse, removeQRCInformation: Bool = true, song: Song? = nil) -> [LyricLine] {
        parseWithFormat(response, removeQRCInformation: removeQRCInformation, song: song).lines
    }

    static func parseWithFormat(_ response: LyricResponse, removeQRCInformation: Bool = true, song: Song? = nil) -> (lines: [LyricLine], format: LyricFormat) {
        if let yrc = response.yrc, !yrc.isEmpty {
            let parsed = parseYRC(yrc)
            let lines = removeQRCInformation ? QRCInformationFilter.remove(from: parsed, song: song) : parsed
            if !parsed.isEmpty {
                return (align(align(lines, source: response.ytlrc ?? response.lrctrans, roman: false), source: response.yromalrc ?? response.romalrc, roman: true), .yrc)
            }
        }
        if let qrc = response.qrc, !qrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parseQRC(qrc)
            let lines = removeQRCInformation ? QRCInformationFilter.remove(from: parsed, song: song) : parsed
            // An all-metadata QRC is a valid empty result. Falling back to LRC
            // here would reintroduce the information the listener just hid.
            if !parsed.isEmpty {
                return (align(align(lines, source: response.qrctrans ?? response.lrctrans, roman: false), source: response.qrcroma, roman: true), .qrc)
            }
        }
        if let lrc = response.lrc { return (align(align(parseLRC(lrc), source: response.lrctrans, roman: false), source: response.romalrc, roman: true), .lrc) }
        return ([], .lrc)
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
            return LyricLine(id: "lrc-\(index)-\(start)", words: [.init(startTime: start, endTime: start + 3_000, word: text)], startTime: start, endTime: start + 3_000, isLineTimed: true)
        }
        guard result.count > 1 else { return result }
        for index in 0..<(result.count - 1) {
            result[index].endTime = result[index + 1].startTime
            for wordIndex in result[index].words.indices { result[index].words[wordIndex].endTime = result[index + 1].startTime }
        }
        return result
    }

    private static func parseYRC(_ source: String) -> [LyricLine] {
        let linePattern = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let wordPattern = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^()]*)"#)
        return source.split(whereSeparator: \.isNewline).enumerated().compactMap { index, raw in
            let line = String(raw) as NSString
            guard let timing = linePattern.firstMatch(in: String(raw), range: NSRange(location: 0, length: line.length)) else { return nil }
            let start = Int64(line.substring(with: timing.range(at: 1))) ?? 0
            let duration = Int64(line.substring(with: timing.range(at: 2))) ?? 0
            let range = NSRange(location: timing.range.length, length: line.length - timing.range.length)
            let words = wordPattern.matches(in: String(raw), range: range).compactMap { match -> LyricWord? in
                let text = decode(line.substring(with: match.range(at: 3)))
                guard !text.isEmpty else { return nil }
                let wordStart = Int64(line.substring(with: match.range(at: 1))) ?? start
                let wordDuration = Int64(line.substring(with: match.range(at: 2))) ?? 0
                return .init(startTime: wordStart, endTime: wordStart + wordDuration, word: text)
            }
            guard !words.isEmpty else { return nil }
            return LyricLine(id: "yrc-\(index)-\(start)", words: words, startTime: start, endTime: start + duration)
        }
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

/// Matches the UI project's QRC metadata rules without using word-duration
/// equality as a heuristic. Source: MeT-Music_UI, commit 02e8fd2c98d164aad0484b80691ce4050808811e,
/// packages/core/src/lyrics/{parse,song-info}.ts.
private enum QRCInformationFilter {
    static func remove(from lines: [LyricLine], song: Song?) -> [LyricLine] {
        let firstContent = lines.firstIndex { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let names = ([song?.name ?? ""] + (song?.artists.map(\.name) ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let artists = (song?.artists.map(\.name) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.enumerated().compactMap { index, line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = index == firstContent && (
                (text.contains("-") && names.contains { text.contains($0) })
                || (line.startTime == 0 && matches(#"\s-\s"#, text))
            )
            let artistLabel = (text.hasSuffix(":") || text.hasSuffix("："))
                && artists.contains { text.contains($0) }
            let plan = text.contains("计划") && ["酷狗", "音乐人", "QQ音乐"].contains { text.contains($0) }
            let untimed = line.startTime == 0 && line.endTime == 0
                && line.words.allSatisfy { $0.startTime == $0.endTime }
            let metadata = title || artistLabel || plan || untimed || isCreditHeader(text)
                || matches(#"未[经經].*[许許]可.*(?:不得|禁止)"#, text)
                || matches(#"by[:：]"#, text, options: .caseInsensitive)
            return metadata ? nil : line
        }
    }

    private static func matches(_ pattern: String, _ text: String, options: String.CompareOptions = []) -> Bool {
        text.range(of: pattern, options: options.union(.regularExpression)) != nil
    }

    /// Recognize complete role headers, including bilingual combinations and
    /// suffixes. Position states avoid exponential regex backtracking on long
    /// repeated headers; ordinary text before a colon must match in full.
    private static func isCreditHeader(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let head = Array(text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let count = head.count
        guard count > 0 else { return false }
        var unitStart = Array(repeating: false, count: count + 1)
        var afterPrefix = unitStart
        var afterRole = unitStart
        unitStart[0] = true
        func advance(_ index: Int, tokens: [[Character]], into states: inout [Bool]) {
            for token in tokens where head[index...].starts(with: token) {
                states[index + token.count] = true
            }
        }
        for index in 0...count {
            if afterRole[index] {
                if index == count { return true }
                advance(index, tokens: suffixes, into: &afterRole)
                var next = index
                while next < count && head[next].isWhitespace { next += 1 }
                if next < count && "/／&".contains(head[next]) {
                    next += 1
                    while next < count && head[next].isWhitespace { next += 1 }
                }
                unitStart[index] = true
                unitStart[next] = true
            }
            if unitStart[index] { advance(index, tokens: prefixes, into: &afterPrefix) }
            if unitStart[index] || afterPrefix[index] { advance(index, tokens: roles, into: &afterRole) }
        }
        return false
    }

    private static let roles: [[Character]] = [
        "作词", "作曲", "说唱作曲", "原唱", "中文填词", "说唱填词",
        "填词", "改编词", "词曲", "作词作曲", "填詞", "中文填詞",
        "词", "曲", "原", "作詞", "詞", "总制作人",
        "联合制作人", "音乐制作", "监制", "音乐总监", "项目总监", "营销推广",
        "编曲", "編曲", "制作", "總製作人", "聯合製作人", "製作",
        "音樂製作", "監製", "混音", "母带", "和声", "和音",
        "配唱", "人声", "录音勤务", "录音", "声乐指导", "配乐",
        "音频编辑", "剪辑", "音乐编辑", "母帶", "錄音", "剪輯",
        "和聲", "器乐团队", "戏曲", "引用", "乐队", "吉他",
        "贝斯", "鼓", "键盘", "弦乐", "管乐", "打击乐",
        "演唱", "合唱", "貝斯", "鍵盤", "弦樂", "出品",
        "特别鸣谢", "歌曲营销", "策划", "策劃", "运营", "運營",
        "推广", "推廣", "项目企划", "企划", "统筹", "总监",
        "總監", "版权", "版權", "发行", "商务", "营销",
        "宣传", "發行", "企劃", "統籌", "OP", "SP",
        "Lyrics", "Lyricist", "Lyrics by", "Written by", "Words by", "Music",
        "Music by", "Composer", "Composed by", "Arranger", "Arranged by", "Arrangement",
        "Producer", "Produced by", "Executive Producer", "Co-Producer", "Mixing", "Mixed by",
        "Mixing Engineer", "Mastering", "Mastered by", "Mastering Engineer", "Recording", "Recorded by",
        "Recording Engineer", "Vocal Director", "Backing Vocals", "Vocal", "Vocals", "Backing Vocal",
        "Crowd Vocals", "Studio", "Guitar", "Bass", "Drums", "Keyboard",
        "Piano", "Strings", "Programming", "Publisher", "Label", "Coordinator"
    ].map { Array($0.lowercased()) }

    private static let prefixes: [[Character]] = [
        "音频", "音頻", "总", "總", "大", "联合",
        "聯合", "共同", "执行", "執行", "项目", "項目",
        "艺术", "藝術", "音乐", "音樂", "人声", "人聲",
        "弦乐", "弦樂", "乐队", "樂隊", "和声", "和聲",
        "歌曲", "版权", "版權", "宣传", "宣傳"
    ].map { Array($0.lowercased()) }

    private static let suffixes: [[Character]] = [
        "师", "師", "工程师", "工程師", "管理", "后期",
        "後期", "室", "棚", "助理", "统筹", "統籌",
        "处理", "處理", "录音", "錄音", "编写", "編寫",
        "指导", "指導", "协力", "協力", "总监", "總監",
        "监制", "監製", "编辑", "編輯", "策划", "策劃",
        "企划", "企劃", "人", "方"
    ].map { Array($0.lowercased()) }
}
