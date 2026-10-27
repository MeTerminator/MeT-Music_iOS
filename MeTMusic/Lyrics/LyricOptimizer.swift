import Foundation

public struct OptimizeLyricOptions: Hashable, Sendable {
    public var normalizeSpaces = true
    public var resetLineTimestamps = true
    public var convertExcessiveBackgroundLines = true
    public var syncMainAndBackgroundLines = true
    public var cleanUnintentionalOverlaps = true
    public var tryAdvanceStartTime = true

    public init() {}
}

public func optimizeLyricLines(
    _ source: [LyricLine],
    options: OptimizeLyricOptions = .init()
) -> [LyricLine] {
    var lines = source.map { line in
        var result = line
        if options.normalizeSpaces {
            result.words = line.words.map { word in
                var value = word
                value.word = word.word
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: #"[^\S\n\u2028\u2029]+"#, with: " ", options: .regularExpression)
                return value
            }
        }
        return result
    }
    if options.resetLineTimestamps {
        for index in lines.indices where !lines[index].words.isEmpty {
            if lines[index].words.count == 1,
               lines[index].words[0].startTime == 0,
               lines[index].words[0].endTime == 0,
               lines[index].startTime != 0 || lines[index].endTime != 0 {
                lines[index].words[0].startTime = lines[index].startTime
                lines[index].words[0].endTime = lines[index].endTime
            } else {
                lines[index].startTime = lines[index].words.first!.startTime
                lines[index].endTime = lines[index].words.last!.endTime
            }
        }
    }
    if options.convertExcessiveBackgroundLines {
        var count = 0
        for index in lines.indices {
            if lines[index].isBackground {
                count += 1
                if count > 1 { lines[index].isBackground = false }
            } else { count = 0 }
        }
    }
    if options.syncMainAndBackgroundLines, lines.count > 1 {
        for index in stride(from: lines.count - 2, through: 0, by: -1) where !lines[index].isBackground && lines[index + 1].isBackground {
            let words = (lines[index].words + lines[index + 1].words).filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let start = words.map(\.startTime).min(), let end = words.map(\.endTime).max() else { continue }
            let groupStart = min(start, lines[index].startTime, lines[index + 1].startTime)
            let groupEnd = max(end, lines[index].endTime, lines[index + 1].endTime)
            lines[index].startTime = groupStart
            lines[index + 1].startTime = groupStart
            lines[index].endTime = groupEnd
            lines[index + 1].endTime = groupEnd
        }
    }
    if options.cleanUnintentionalOverlaps, lines.count > 1 {
        for index in 0..<(lines.count - 1) where !lines[index].isBackground {
            var next = index + 1
            while next < lines.count && lines[next].isBackground { next += 1 }
            guard next < lines.count else { continue }
            let overlap = lines[index].endTime - lines[next].startTime
            let duration = lines[next].endTime - lines[next].startTime
            if overlap > 0 && !(overlap > 100 && Double(overlap) > Double(duration) * 0.1) {
                lines[index].endTime = lines[next].startTime
                if index + 1 < lines.count, lines[index + 1].isBackground {
                    lines[index + 1].endTime = lines[next].startTime
                }
            }
        }
    }
    if options.tryAdvanceStartTime {
        var previousStart: Int64 = 0
        var previousEnd: Int64 = 0
        var groupStart: Int64 = 0
        var groupEnd: Int64 = 0
        var hasPrevious = false
        for index in lines.indices where !lines[index].isBackground {
            let originalStart = lines[index].startTime
            let originalEnd = lines[index].endTime
            let advance: Int64 = !hasPrevious || originalStart >= previousEnd ? 600 : 400
            let boundary: Int64 = !hasPrevious ? 0 : (originalStart >= previousEnd ? groupEnd : previousStart + Int64(Double(previousEnd - previousStart) * 0.3))
            if !lines[index].isLineTimed {
                lines[index].startTime = max(boundary, originalStart - advance)
            }
            if index + 1 < lines.count, lines[index + 1].isBackground { lines[index + 1].startTime = lines[index].startTime }
            if hasPrevious && originalStart < groupEnd && originalEnd > groupStart {
                groupStart = min(groupStart, originalStart)
                groupEnd = max(groupEnd, originalEnd)
            } else {
                groupStart = originalStart
                groupEnd = originalEnd
            }
            previousStart = originalStart
            previousEnd = originalEnd
            hasPrevious = true
        }
    }
    return lines
}
