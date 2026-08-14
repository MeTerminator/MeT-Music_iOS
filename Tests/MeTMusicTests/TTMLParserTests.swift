import Testing
@testable import MeTMusic

@Suite struct TTMLParserTests {
    private let document = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml"
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
        xmlns:amll="https://github.com/Steve-xmh/amll-ttml-tool"
        xml:lang="en" ttm:timing="Word">
      <head>
        <metadata>
          <ttm:title>Demo</ttm:title>
          <ttm:agent xml:id="v1" type="person"><ttm:name>Lead</ttm:name></ttm:agent>
          <amll:meta key="artists" value="Tester" />
          <iTunesMetadata>
            <translations>
              <translation xml:lang="zh-Hans"><text for="L1">你好</text></translation>
            </translations>
            <transliterations>
              <transliteration xml:lang="latin">
                <text for="L1"><span begin="00:00:01.000" end="00:00:01.500">he</span><span begin="00:00:01.500" end="00:00:02.000">llo</span></text>
              </transliteration>
            </transliterations>
          </iTunesMetadata>
        </metadata>
      </head>
      <body>
        <div>
          <p xml:id="L1" ttm:agent="v1" begin="00:00:01.000" end="00:00:02.000">
            <span begin="00:00:01.000" end="00:00:01.500">Hel</span><span begin="00:00:01.500" end="00:00:02.000">lo </span>
            <span ttm:role="x-bg" begin="00:00:01.200" end="00:00:01.900">(<span begin="00:00:01.200" end="00:00:01.900">hey</span>)</span>
          </p>
        </div>
      </body>
    </tt>
    """#

    @Test func parsesWordTimingSidecarsAndBackgroundVocal() throws {
        let result = try TTMLParser.parseAMLL(document, translationLanguage: "zh-Hans", romanizationLanguage: "latin")
        #expect(result.lines.count == 2)
        #expect(result.lines[0].text == "Hello")
        #expect(result.lines[0].words.map(\.startTime) == [1_000, 1_500])
        #expect(result.lines[0].translatedLyric == "你好")
        #expect(result.lines[0].words.map(\.romanWord) == ["he", "llo"])
        #expect(result.lines[1].isBackground)
        #expect(result.lines[1].text == "hey")
        #expect(result.metadata["musicName"] == ["Demo"])
        #expect(result.metadata["artists"] == ["Tester"])
        #expect(result.metadata["language"] == ["en"])
        #expect(result.metadata["timingMode"] == ["Word"])
    }

    @Test func timeFormats() {
        #expect(TTMLParser.parseTime("01:02:03.456") == 3_723_456)
        #expect(TTMLParser.parseTime("03.5s") == 3_500)
        #expect(TTMLParser.parseTime("250ms") == 250)
        #expect(TTMLParser.parseTime(nil) == 0)
    }

    @Test func rejectsInvalidRoot() {
        #expect(throws: TTMLParserError.invalidRoot) {
            try TTMLParser.parseAMLL("<html />")
        }
    }
}
