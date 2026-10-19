import Foundation

public struct LyricWordBase: Hashable, Sendable {
    public var startTime: Int64
    public var endTime: Int64
    public var word: String

    public init(startTime: Int64, endTime: Int64, word: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.word = word
    }
}

public struct LyricWord: Hashable, Sendable, Identifiable {
    public var startTime: Int64
    public var endTime: Int64
    public var word: String
    public var romanWord: String
    public var isObscene: Bool
    public var emptyBeat: Int?
    public var ruby: [LyricWordBase]

    public var id: String { "\(startTime):\(endTime):\(word)" }

    public init(
        startTime: Int64,
        endTime: Int64,
        word: String,
        romanWord: String = "",
        isObscene: Bool = false,
        emptyBeat: Int? = nil,
        ruby: [LyricWordBase] = []
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.word = word
        self.romanWord = romanWord
        self.isObscene = isObscene
        self.emptyBeat = emptyBeat
        self.ruby = ruby
    }
}

public struct LyricLine: Hashable, Sendable, Identifiable {
    public var id: String
    public var words: [LyricWord]
    public var translatedLyric: String
    public var romanLyric: String
    public var startTime: Int64
    public var endTime: Int64
    public var isBackground: Bool
    public var isDuet: Bool
    /// The source supplies line timestamps only; do not synthesize word progress.
    public var isLineTimed: Bool

    public var text: String { words.map(\.word).joined() }

    public init(
        id: String = UUID().uuidString,
        words: [LyricWord],
        translatedLyric: String = "",
        romanLyric: String = "",
        startTime: Int64,
        endTime: Int64,
        isBackground: Bool = false,
        isDuet: Bool = false,
        isLineTimed: Bool = false
    ) {
        self.id = id
        self.words = words
        self.translatedLyric = translatedLyric
        self.romanLyric = romanLyric
        self.startTime = startTime
        self.endTime = endTime
        self.isBackground = isBackground
        self.isDuet = isDuet
        self.isLineTimed = isLineTimed
    }
}

public struct AMLLLyricResult: Hashable, Sendable {
    public var lines: [LyricLine]
    public var metadata: [String: [String]]

    public init(lines: [LyricLine], metadata: [String: [String]] = [:]) {
        self.lines = lines
        self.metadata = metadata
    }
}

public struct LyricTimeBounds: Hashable, Sendable {
    public var startTime: Int64
    public var endTime: Int64

    public init(startTime: Int64, endTime: Int64) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct LyricTimelineSnapshot: Equatable, Sendable {
    public var playingIndices: Set<Int>
    public var highlightedIndices: Set<Int>
    public var scrollTargetIndex: Int
    public var isSeeking: Bool
}
