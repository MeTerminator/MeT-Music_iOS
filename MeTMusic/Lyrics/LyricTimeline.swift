import Foundation

/// Stateful boundary-indexed timeline. Ordinary playback touches only boundaries
/// crossed since the previous tick, while discontinuous seeks rebuild the state.
public final class LyricTimeline {
    private let bounds: [LyricTimeBounds]
    private let startOrder: [Int]
    private let endOrder: [Int]
    private var playing = Set<Int>()
    private var highlighted = Set<Int>()
    private var scrollTarget = 0
    private var previousTime: Int64?
    private var startCursor = 0
    private var endCursor = 0
    private var cached = LyricTimelineSnapshot(
        playingIndices: [], highlightedIndices: [], scrollTargetIndex: 0, isSeeking: false
    )

    public init(bounds authoredBounds: [LyricTimeBounds], lineTransitionLeadMs: Int64 = 0) {
        let bounds = lyricTransitionBounds(authoredBounds, lineTransitionLeadMs: lineTransitionLeadMs)
        self.bounds = bounds
        startOrder = bounds.indices.sorted {
            bounds[$0].startTime == bounds[$1].startTime ? $0 < $1 : bounds[$0].startTime < bounds[$1].startTime
        }
        endOrder = bounds.indices.sorted {
            bounds[$0].endTime == bounds[$1].endTime ? $0 < $1 : bounds[$0].endTime < bounds[$1].endTime
        }
    }

    public convenience init(lines: [LyricLine]) {
        self.init(bounds: lines.map { .init(startTime: $0.startTime, endTime: $0.endTime) })
    }

    public func sync(timeMs: Int64, forceSeek: Bool = false) -> LyricTimelineSnapshot {
        let last = previousTime
        let seeking = forceSeek || last.map { timeMs < $0 || abs(timeMs - $0) > 1_000 } == true
        if last == nil || seeking {
            rebuild(at: timeMs)
        } else {
            var added = Set<Int>()
            var changed = false
            while startCursor < startOrder.count,
                  bounds[startOrder[startCursor]].startTime <= timeMs {
                let index = startOrder[startCursor]
                startCursor += 1
                if bounds[index].endTime > timeMs, playing.insert(index).inserted {
                    added.insert(index)
                    changed = true
                }
            }
            while endCursor < endOrder.count,
                  bounds[endOrder[endCursor]].endTime <= timeMs {
                let index = endOrder[endCursor]
                endCursor += 1
                if playing.remove(index) != nil { changed = true }
            }
            if changed {
                reconcileHighlights(added: added)
                cached = snapshot(seeking: false)
            } else if cached.isSeeking {
                cached.isSeeking = false
            }
        }
        // An overlapping upper line can finish without another line starting.
        // Follow the first line still playing even if highlights are held over.
        if !seeking, let first = playing.min() {
            scrollTarget = first
            cached.scrollTargetIndex = first
        }
        previousTime = timeMs
        if last == nil || seeking { cached = snapshot(seeking: seeking) }
        return cached
    }

    private func rebuild(at time: Int64) {
        playing = Set(bounds.indices.filter { time >= bounds[$0].startTime && time < bounds[$0].endTime })
        highlighted = playing
        // Seeking anchors on the lyric that started most recently. Overlapping
        // lyrics — duets, a line held over the next one — would otherwise pull
        // the view back to a lyric that began long before the tapped one.
        scrollTarget = playing.max(by: {
            (bounds[$0].startTime, $0) < (bounds[$1].startTime, $1)
        })
            ?? bounds.firstIndex(where: { $0.startTime >= time })
            ?? max(0, bounds.count - 1)
        startCursor = startOrder.firstIndex { bounds[$0].startTime > time } ?? startOrder.count
        endCursor = endOrder.firstIndex { bounds[$0].endTime > time } ?? endOrder.count
    }

    private func reconcileHighlights(added: Set<Int>) {
        let expired = highlighted.subtracting(playing)
        highlighted.formUnion(added)
        let allFinished = !expired.isEmpty && expired.count == highlighted.count
        if (!added.isEmpty || allFinished) && !expired.isEmpty { highlighted.subtract(expired) }
        if (!added.isEmpty || allFinished), let minimum = highlighted.min() { scrollTarget = minimum }
    }

    private func snapshot(seeking: Bool) -> LyricTimelineSnapshot {
        .init(
            playingIndices: playing,
            highlightedIndices: highlighted,
            scrollTargetIndex: min(max(scrollTarget, 0), max(bounds.count - 1, 0)),
            isSeeking: seeking
        )
    }
}
