import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum TTMLParserError: LocalizedError, Equatable {
    case emptyInput
    case malformedXML(String)
    case invalidRoot

    public var errorDescription: String? {
        switch self {
        case .emptyInput: "TTML input is empty."
        case let .malformedXML(message): "Malformed TTML: \(message)"
        case .invalidRoot: "TTML root element must be <tt>."
        }
    }
}

/// Namespace-tolerant Apple Music / AMLL TTML parser.
public enum TTMLParser {
    public static func parseAMLL(
        _ source: String,
        translationLanguage: String? = nil,
        romanizationLanguage: String? = nil
    ) throws -> AMLLLyricResult {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTMLParserError.emptyInput
        }
        let builder = XMLTreeBuilder()
        guard let data = source.data(using: .utf8) else { throw TTMLParserError.malformedXML("Invalid UTF-8") }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw TTMLParserError.malformedXML(parser.parserError?.localizedDescription ?? "Unknown XML error")
        }
        guard root.localName == "tt" else { throw TTMLParserError.invalidRoot }
        return DocumentParser(
            root: root,
            translationLanguage: translationLanguage,
            romanizationLanguage: romanizationLanguage
        ).parse()
    }

    public static func parseTime(_ value: String?) -> Int64 {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return 0 }
        if text.hasSuffix("ms"), let ms = Double(text.dropLast(2)) { return Int64(ms.rounded()) }
        if text.hasSuffix("s"), let seconds = Double(text.dropLast()) { return Int64((seconds * 1_000).rounded()) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let seconds = Double(parts.last!) else { return 0 }
        let minutes = parts.count >= 2 ? Int64(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count == 3 ? Int64(parts[0]) ?? 0 : 0
        return Int64((Double(hours * 3_600 + minutes * 60) + seconds) * 1_000.0 + 0.5)
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    weak var parent: XMLNode?
    var content: [XMLContent] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var localName: String { name.split(separator: ":").last.map(String.init) ?? name }
    var children: [XMLNode] { content.compactMap { if case let .element(node) = $0 { node } else { nil } } }
    var textContent: String { localName == "br" ? "\u{2028}" : content.map { $0.text }.joined() }

    func attribute(_ name: String) -> String? {
        attributes.first { ($0.key.split(separator: ":").last.map(String.init) ?? $0.key) == name }?.value
    }

    func descendants(named name: String) -> [XMLNode] {
        children.flatMap { child in
            (child.localName == name ? [child] : []) + child.descendants(named: name)
        }
    }

    func firstDescendant(named name: String) -> XMLNode? { descendants(named: name).first }
}

private enum XMLContent {
    case text(String)
    case element(XMLNode)

    var text: String {
        switch self {
        case let .text(value): value
        case let .element(node): node.textContent
        }
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last {
            node.parent = parent
            parent.content.append(.element(node))
        } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last else { return }
        if case let .text(previous)? = node.content.last {
            node.content[node.content.count - 1] = .text(previous + string)
        } else { node.content.append(.text(string)) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) { _ = stack.popLast() }
}

private struct ParsedSyllable {
    var text: String
    var start: Int64
    var end: Int64
    var endsWithSpace = false
    var endsWithLineBreak = false
    var ruby: [LyricWordBase] = []
    var isObscene = false
    var emptyBeat: Int?
}

private struct SubContent {
    var text: String
    var language: String?
    var words: [ParsedSyllable] = []
}

private final class ParsedContent {
    var text = ""
    var start: Int64 = 0
    var end: Int64 = 0
    var words: [ParsedSyllable] = []
    var translations: [SubContent] = []
    var romanizations: [SubContent] = []
    var background: ParsedContent?
}

private final class Sidecar {
    var translations: [SubContent] = []
    var romanizations: [SubContent] = []
    var backgroundTranslations: [SubContent] = []
    var backgroundRomanizations: [SubContent] = []
}

private struct Agent {
    var type: String?
    var name: String?
}

private struct RawLine {
    var id: String
    var agentID: String
    var content: ParsedContent
}

private final class DocumentParser {
    let root: XMLNode
    let translationLanguage: String?
    let romanizationLanguage: String?
    var sidecars: [String: Sidecar] = [:]
    var agents: [String: Agent] = [:]
    var metadata: [String: [String]] = [:]

    init(root: XMLNode, translationLanguage: String?, romanizationLanguage: String?) {
        self.root = root
        self.translationLanguage = translationLanguage
        self.romanizationLanguage = romanizationLanguage
    }

    func parse() -> AMLLLyricResult {
        parseHead()
        let rawLines = parseBody()
        var lines: [LyricLine] = []
        var lastPersonAgent: String?
        var lastPersonDuet = false
        for raw in rawLines {
            let agent = agents[raw.agentID]
            let duet: Bool
            if agent?.type == "group" {
                duet = false
            } else if lastPersonAgent == nil {
                duet = agent?.type == "other"
                lastPersonAgent = raw.agentID
                lastPersonDuet = duet
            } else if lastPersonAgent == raw.agentID {
                duet = lastPersonDuet
            } else {
                duet = !lastPersonDuet
                lastPersonAgent = raw.agentID
                lastPersonDuet = duet
            }
            lines.append(convert(raw.content, id: raw.id, background: false, duet: duet))
            if let background = raw.content.background {
                lines.append(convert(background, id: raw.id + ":background", background: true, duet: duet))
            }
        }
        let timing = root.attribute("timing").flatMap { ["Word", "Line"].contains($0) ? $0 : nil }
            ?? (lines.contains { $0.words.count > 1 } ? "Word" : "Line")
        metadata["language"] = root.attribute("lang").map { [$0] }
        metadata["timingMode"] = [timing]
        return .init(lines: optimizeLyricLines(lines), metadata: metadata)
    }

    private func parseHead() {
        guard let head = root.firstDescendant(named: "head") else { return }
        if let title = clean(head.descendants(named: "title").first?.textContent), !title.isEmpty { appendMeta("musicName", title) }
        for node in head.descendants(named: "agent") {
            guard let id = node.attribute("id") else { continue }
            agents[id] = Agent(type: node.attribute("type"), name: clean(node.descendants(named: "name").first?.textContent))
        }
        for node in head.descendants(named: "meta") {
            guard let key = node.attribute("key"), let value = clean(node.attribute("value")), !value.isEmpty else { continue }
            appendMeta(key, value)
        }
        for node in head.descendants(named: "songwriter") {
            if let value = clean(node.textContent), !value.isEmpty { appendMeta("songwriters", value) }
        }
        for container in head.descendants(named: "iTunesMetadata") {
            parseSidecar(container, containerName: "translations", itemName: "translation", isTranslation: true)
            parseSidecar(container, containerName: "transliterations", itemName: "transliteration", isTranslation: false)
        }
    }

    private func appendMeta(_ key: String, _ value: String) {
        if metadata[key]?.contains(value) != true { metadata[key, default: []].append(value) }
    }

    private func parseSidecar(_ metadata: XMLNode, containerName: String, itemName: String, isTranslation: Bool) {
        guard let container = metadata.descendants(named: containerName).first else { return }
        for item in container.descendants(named: itemName) {
            let language = item.attribute("lang")
            for textNode in item.descendants(named: "text") {
                guard let lineID = textNode.attribute("for") else { continue }
                let parsed = parseContent(textNode)
                let values = subContent(parsed, language: language)
                let target = sidecars[lineID] ?? Sidecar()
                sidecars[lineID] = target
                if isTranslation {
                    if let main = values.0 { target.translations.append(main) }
                    if let background = values.1 { target.backgroundTranslations.append(background) }
                } else {
                    if let main = values.0 { target.romanizations.append(main) }
                    if let background = values.1 { target.backgroundRomanizations.append(background) }
                }
            }
        }
    }

    private func parseBody() -> [RawLine] {
        guard let body = root.firstDescendant(named: "body") else { return [] }
        var result: [RawLine] = []
        for child in body.children {
            let paragraphs = child.localName == "div" ? child.descendants(named: "p") : (child.localName == "p" ? [child] : [])
            for paragraph in paragraphs {
                let id = paragraph.attribute("key") ?? paragraph.attribute("id") ?? "line-\(result.count)"
                let content = parseContent(paragraph)
                if let extra = sidecars[id] {
                    content.translations += extra.translations
                    content.romanizations += extra.romanizations
                    content.background?.translations += extra.backgroundTranslations
                    content.background?.romanizations += extra.backgroundRomanizations
                }
                result.append(.init(id: id, agentID: paragraph.attribute("agent") ?? "v1", content: content))
            }
        }
        return result
    }

    private func parseContent(_ element: XMLNode) -> ParsedContent {
        let result = ParsedContent()
        let originalStart = TTMLParser.parseTime(element.attribute("begin"))
        let originalEnd = TTMLParser.parseTime(element.attribute("end"))
        result.start = originalStart
        result.end = originalEnd
        var fullText = ""
        var backgroundTranslations: [SubContent] = []
        var backgroundRomanizations: [SubContent] = []

        for item in element.content {
            switch item {
            case let .text(raw):
                let formatting = raw.contains("\n")
                if formatting && raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let normalized = clean(raw, trim: false) ?? ""
                fullText += normalized
                if !formatting, !normalized.isEmpty,
                   normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !result.words.isEmpty {
                    result.words[result.words.count - 1].endsWithSpace = true
                }
            case let .element(node):
                if node.localName == "br" {
                    appendLineBreak(into: result, fullText: &fullText)
                } else if node.attribute("ruby") == "container" {
                    parseRuby(node, into: result, fullText: &fullText)
                } else {
                    switch node.attribute("role") {
                    case "x-bg":
                        result.background = parseBackground(node)
                    case "x-translation":
                        let values = subContent(parseContent(node), language: node.attribute("lang"), ignoreWords: true)
                        if let main = values.0 { result.translations.append(main) }
                        if let background = values.1 { backgroundTranslations.append(background) }
                    case "x-roman":
                        let values = subContent(parseContent(node), language: node.attribute("lang"), ignoreWords: true)
                        if let main = values.0 { result.romanizations.append(main) }
                        if let background = values.1 { backgroundRomanizations.append(background) }
                    default:
                        parseWord(node, into: result, fullText: &fullText)
                    }
                }
            }
        }
        if !result.words.isEmpty {
            result.words[0].text = result.words[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = result.words.count - 1
            result.words[last].text = result.words[last].text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.words[last].endsWithSpace = false
            result.words[last].endsWithLineBreak = false
        }
        let timed = result.words.map { ($0.start, $0.end) } + (result.background.map { [($0.start, $0.end)] } ?? [])
        if let minimum = timed.map(\.0).min(), result.start == 0 || (minimum > 0 && minimum < result.start) { result.start = minimum }
        if let maximum = timed.map(\.1).max(), result.end == 0 || maximum > result.end { result.end = maximum }
        result.text = clean(fullText) ?? ""
        if result.words.isEmpty, !result.text.isEmpty, element.attribute("begin") != nil || element.attribute("end") != nil {
            result.words = [.init(text: result.text, start: originalStart > 0 ? originalStart : result.start, end: originalEnd > 0 ? originalEnd : result.end)]
        }
        result.background?.translations += backgroundTranslations
        result.background?.romanizations += backgroundRomanizations
        return result
    }

    private func appendLineBreak(into result: ParsedContent, fullText: inout String) {
        fullText += "\u{2028}"
        if !result.words.isEmpty { result.words[result.words.count - 1].endsWithLineBreak = true }
    }

    private func parseWord(_ node: XMLNode, into result: ParsedContent, fullText: inout String) {
        if node.localName == "br" {
            appendLineBreak(into: result, fullText: &fullText)
            return
        }
        guard let begin = node.attribute("begin"), let end = node.attribute("end") else {
            // Formatting wrappers may contain text, timed spans and <br/>.
            for item in node.content {
                switch item {
                case let .text(raw):
                    if raw.contains("\n") && raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    fullText += clean(raw, trim: false) ?? ""
                case let .element(child): parseWord(child, into: result, fullText: &fullText)
                }
            }
            return
        }
        let raw = node.textContent
        let normalized = clean(raw, trim: false) ?? ""
        fullText += normalized
        let formatting = raw.contains("\n")
        if normalized.first == "\u{2028}", !result.words.isEmpty {
            result.words[result.words.count - 1].endsWithLineBreak = true
        } else if !formatting, normalized.first?.isWhitespace == true, !result.words.isEmpty {
            result.words[result.words.count - 1].endsWithSpace = true
        }
        let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        result.words.append(.init(
            text: text,
            start: TTMLParser.parseTime(begin),
            end: TTMLParser.parseTime(end),
            endsWithSpace: !formatting && normalized.last?.isWhitespace == true,
            endsWithLineBreak: normalized.last == "\u{2028}",
            isObscene: node.attribute("obscene") == "true",
            emptyBeat: node.attribute("empty-beat").flatMap(Int.init)
        ))
    }

    private func parseRuby(_ node: XMLNode, into result: ParsedContent, fullText: inout String) {
        guard let rawBase = node.children.first(where: { $0.attribute("ruby") == "base" })?.textContent else { return }
        let ruby = node.children.first(where: { $0.attribute("ruby") == "textContainer" })?.children
            .filter { $0.attribute("ruby") == "text" }
            .compactMap { child -> LyricWordBase? in
                guard let begin = child.attribute("begin"), let end = child.attribute("end"),
                      let text = clean(child.textContent), !text.isEmpty else { return nil }
                return .init(startTime: TTMLParser.parseTime(begin), endTime: TTMLParser.parseTime(end), word: text)
            } ?? []
        fullText += rawBase
        if rawBase.first?.isWhitespace == true, !result.words.isEmpty { result.words[result.words.count - 1].endsWithSpace = true }
        let text = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        result.words.append(.init(
            text: text,
            start: ruby.map(\.startTime).min() ?? 0,
            end: ruby.map(\.endTime).max() ?? 0,
            endsWithSpace: rawBase.last?.isWhitespace == true,
            ruby: ruby,
            isObscene: node.attribute("obscene") == "true",
            emptyBeat: node.attribute("empty-beat").flatMap(Int.init)
        ))
    }

    private func parseBackground(_ node: XMLNode) -> ParsedContent {
        let result = parseContent(node)
        result.text = result.text.replacingOccurrences(of: #"^[（(]+|[）)]+$"#, with: "", options: .regularExpression)
        if !result.words.isEmpty {
            result.words[0].text = result.words[0].text.replacingOccurrences(of: #"^[（(]+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let last = result.words.count - 1
            result.words[last].text = result.words[last].text.replacingOccurrences(of: #"[）)]+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        result.background = nil
        return result
    }

    private func subContent(_ source: ParsedContent, language: String?, ignoreWords: Bool = false) -> (SubContent?, SubContent?) {
        func make(_ content: ParsedContent) -> SubContent? {
            let words = ignoreWords || (content.words.count == 1 && content.words[0].start == 0 && content.words[0].end == 0) ? [] : content.words
            let text = clean(content.text) ?? ""
            return text.isEmpty && words.isEmpty ? nil : .init(text: text, language: language, words: words)
        }
        return (make(source), source.background.flatMap(make))
    }

    private func preferred(_ values: [SubContent], language: String?) -> SubContent? {
        language.flatMap { target in values.first(where: { $0.language == target }) } ?? values.first
    }

    private func convert(_ source: ParsedContent, id: String, background: Bool, duet: Bool) -> LyricLine {
        var words = source.words.isEmpty
            ? [LyricWord(startTime: source.start, endTime: source.end, word: source.text.replacingOccurrences(of: "\u{2028}", with: "\n"))]
            : source.words.map {
                LyricWord(
                    startTime: $0.start,
                    endTime: $0.end,
                    word: $0.text.replacingOccurrences(of: "\u{2028}", with: "\n") + ($0.endsWithLineBreak ? "\n" : ($0.endsWithSpace ? " " : "")),
                    isObscene: $0.isObscene,
                    emptyBeat: $0.emptyBeat,
                    ruby: $0.ruby
                )
            }
        let translation = preferred(source.translations, language: translationLanguage)?.text ?? ""
        let roman = preferred(source.romanizations, language: romanizationLanguage)
        if let romanWords = roman?.words, !romanWords.isEmpty { alignRomanization(&words, romanWords) }
        return .init(
            id: id,
            words: words,
            translatedLyric: translation.replacingOccurrences(of: "\u{2028}", with: "\n"),
            romanLyric: roman?.words.isEmpty == false ? "" : (roman?.text ?? "").replacingOccurrences(of: "\u{2028}", with: "\n"),
            startTime: source.start,
            endTime: source.end,
            isBackground: background,
            isDuet: duet
        )
    }

    private func alignRomanization(_ main: inout [LyricWord], _ roman: [ParsedSyllable]) {
        var searchStart = 0
        for index in main.indices {
            var best: Int?
            var bestIOU = 0.0
            for candidate in searchStart..<roman.count {
                if abs(main[index].startTime - roman[candidate].start) <= 2 {
                    main[index].romanWord = roman[candidate].text
                    searchStart = candidate + 1
                    best = nil
                    break
                }
                let intersection = max(0, min(main[index].endTime, roman[candidate].end) - max(main[index].startTime, roman[candidate].start))
                if intersection > 0 {
                    let union = max(1, max(main[index].endTime, roman[candidate].end) - min(main[index].startTime, roman[candidate].start))
                    let iou = Double(intersection) / Double(union)
                    if iou > bestIOU { bestIOU = iou; best = candidate }
                }
                if roman[candidate].start >= main[index].endTime { break }
            }
            if let best, bestIOU >= 0.1 {
                main[index].romanWord = roman[best].text
                searchStart = best + 1
            }
        }
    }

    private func clean(_ value: String?, trim: Bool = true) -> String? {
        guard let value else { return nil }
        // XML source indentation is collapsible whitespace; <br/> is a
        // structural separator and must survive repeated normalization.
        let normalized = value.components(separatedBy: "\u{2028}")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .joined(separator: "\u{2028}")
        return trim ? normalized.trimmingCharacters(in: .whitespacesAndNewlines) : normalized
    }
}
