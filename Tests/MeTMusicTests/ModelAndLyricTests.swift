import Foundation
import Testing
@testable import MeTMusic

@Suite struct ModelAndLyricTests {
    @Test func choosesPlayableExtensionsForTogetherCache() {
        let endpoint = URL(string: "https://music.met6.top:444/api/web/local/music/file/song")!
        #expect(preferredAudioFileExtension(remoteURL: endpoint, mimeType: "audio/flac") == "flac")
        #expect(preferredAudioFileExtension(remoteURL: endpoint, mimeType: "audio/mpeg") == "mp3")
        #expect(preferredAudioFileExtension(remoteURL: endpoint, suggestedFilename: "track.m4a") == "m4a")
        #expect(preferredAudioFileExtension(remoteURL: URL(string: "https://example.com/track.aac?token=1")!) == "aac")
    }

    @Test func roomSongUsesFormattedDurationAsFallback() throws {
        let data = Data(#"{"id":"1","name":"Song","duration":"03:42"}"#.utf8)
        let song = try JSONDecoder().decode(RoomSong.self, from: data).song
        #expect(song.durationMs == 222_000)
    }

    @Test func rewritesServerLoopbackAssetURLs() {
        let url = RemoteAssetURL.make("https://localhost/api/web/local/music/file/003hiN8a17iM5i.jpg")
        #expect(url?.absoluteString == "https://music.met6.top:444/api/web/local/music/file/003hiN8a17iM5i.jpg")

        let audioURL = RemoteAssetURL.make("http://127.0.0.1/api/web/local/music/file/song.flac?token=abc")
        #expect(audioURL?.absoluteString == "https://music.met6.top:444/api/web/local/music/file/song.flac?token=abc")
    }

    @Test func playerArtworkStaysInsideItsPage() {
        let portrait = CGSize(width: 402, height: 874)
        #expect(abs(playerArtworkSide(in: portrait) - (portrait.width - 48) * 0.85) < 0.001)

        let landscape = CGSize(width: 874, height: 402)
        let landscapeSide = playerArtworkSide(in: landscape)
        #expect(landscapeSide <= landscape.width * 0.8)
        #expect(landscapeSide <= landscape.height * 0.54)

        #expect(playerArtworkSide(in: .zero) == 0)
    }

    @Test func decodesFlexibleQQMusicModels() throws {
        let data = Data(#"""
        {
          "id": 123,
          "mid": "MID123",
          "name": "Test",
          "ar": [{"id": 7, "name": "Artist"}],
          "al": {"id": 9, "name": "Album", "picUrl": "//example.com/cover.jpg"},
          "dt": "125000",
          "ttml": "1"
        }
        """#.utf8)
        let song = try JSONDecoder().decode(Song.self, from: data)
        #expect(song.id == "123")
        #expect(song.artists.first?.id == "7")
        #expect(song.durationMs == 125_000)
        #expect(song.ttml == 1)
        #expect(song.hasTTML)
        #expect(song.bestCoverURL?.absoluteString == "https://example.com/cover.jpg")
    }

    @Test func decodesPlaylistTTMLAvailabilityFromAPI() throws {
        let data = Data(#"""
        {
          "songs": [
            {"id":"without","name":"Without TTML","ar":[],"dt":1000,"ttml":0},
            {"id":"with","name":"With TTML","ar":[],"dt":1000,"ttml":1},
            {"id":"missing","name":"Legacy Response","ar":[],"dt":1000}
          ]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(PlaylistTracksResponse.self, from: data)
        #expect(response.songs.map(\.hasTTML) == [false, true, false])
    }

    @Test func lrcAlignsTranslationAndExtendsUntilNextLine() {
        let response = LyricResponse(
            lrc: "[00:01.00]Hello\n[00:03.500]World",
            lrctrans: "[00:01.05]你好\n[00:03.500]世界",
            qrc: nil,
            qrctrans: nil,
            qrcroma: nil
        )
        let lines = OrdinaryLyricParser.parse(response)
        #expect(lines.count == 2)
        #expect(lines[0].startTime == 1_000)
        #expect(lines[0].endTime == 3_500)
        #expect(lines[0].translatedLyric == "你好")
    }

    @Test func qrcInformationRemovalMatchesUIBehavior() {
        let qrc = """
        [0,1000]歌名 - 歌手(0,1000)
        [1000,1000]作词(1000,500)：某人(1500,500)
        [2000,1000]正文(2000,1000)
        """
        let response = LyricResponse(lrc: nil, lrctrans: nil, qrc: qrc, qrctrans: nil, qrcroma: nil)
        #expect(OrdinaryLyricParser.parse(response, removeQRCInformation: false).count == 3)
        let filtered = OrdinaryLyricParser.parse(response, removeQRCInformation: true)
        #expect(filtered.count == 1)
        #expect(filtered[0].text == "正文")
    }

    @Test(arguments: [
        "词曲:张三", "Producer:X", "作詞:山田", "編曲／混音:李四", "mixed by: Y",
        "词 Lyricist：五月天 阿信", "共同制作人 Co-Producer：詹宏业",
        "编曲 Music Arrangement：五月天 阿信", "编曲协力 Music Arrangement Coordinator：黄庆原",
        "和声编写/演唱 Backing Vocal/Arrangement：洪俊扬", "大合唱 Crowd Vocals：詹宏业",
        "母带后期处理工程师 Mastering Engineer：Wayson", "母带后期处理录音室 Mastering Studio：Wayson",
        "艺术总监：李朋", "母带处理工程师：赵靖", "总策划/监制：李静楠", "混音室：@SBMS",
        "配唱制作人：吴青峰/陈君豪", "音频剪辑：叶育轩/陈君豪", "词曲版权管理：索尼音乐",
        "器乐团队：乐手", "说唱作曲：作者", "戏曲：演员", "引用：作品"
    ])
    func qrcRemovesCreditsAnywhereWithoutShiftingSidecars(credit: String) {
        let response = qrcResponse(["歌词一", credit, "歌词二"])
        let lines = OrdinaryLyricParser.parse(response)
        #expect(lines.map(\.text) == ["歌词一", "歌词二"])
        #expect(lines.map(\.translatedLyric) == ["译一", "译二"])
        #expect(lines.map(\.romanLyric) == ["roma1", "roma2"])
        #expect(OrdinaryLyricParser.parse(response, removeQRCInformation: false).map(\.text) == ["歌词一", credit, "歌词二"])
    }

    @Test func qrcPreservesFirstLyricUniformTimingAndOrdinaryColons() {
        let texts = ["词穷了", "Producer of dreams", "Music is my life：yeah", "总有一天：我会", "女：", "男：", "合：", "A - B"]
        let lines = OrdinaryLyricParser.parse(qrcResponse(texts))
        #expect(lines.map(\.text) == texts)
        let response = LyricResponse(lrc: nil, lrctrans: nil,
            qrc: "[0,1000]第(0,250)一(250,250)句(500,250)啊(750,250)", qrctrans: nil, qrcroma: nil)
        #expect(OrdinaryLyricParser.parse(response).first?.text == "第一句啊")
    }

    @Test func qrcUsesSongIdentityForTitleAndArtistLabels() {
        let texts = ["测试歌曲-另一位歌手", "歌手甲：", "歌词", "歌手甲：唱出歌词", "陌生人：", "测试歌曲-正文保留"]
        let song = Song(id: "test", name: "测试歌曲", artists: [.init(id: "artist", name: " 歌手甲 ")])
        let lines = OrdinaryLyricParser.parse(qrcResponse(texts), song: song)
        #expect(lines.map(\.text) == Array(texts.dropFirst(2)))
        #expect(OrdinaryLyricParser.parse(qrcResponse(["别的歌曲-歌手", "歌词"]), song: song).count == 2)
    }

    @Test func qrcRemovesUntimedTitlesCopyrightPromotionsAndByCredits() {
        let texts = ["正文", "【未经著作权人书面许可，不得以任何方式使用。】", "QQ音乐计划", "计划支持酷狗", "音乐人扶持计划", "整理 By：某人", "歌词尾声"]
        var response = qrcResponse(texts)
        response.qrc = "[0,0]晴(0,0)天(0,0)\n[0,0](0,0)\n" + (response.qrc ?? "")
        #expect(OrdinaryLyricParser.parse(response).map(\.text) == ["正文", "歌词尾声"])
    }

    @Test func qrcAllMetadataDoesNotReappearThroughLRCFallback() {
        let response = LyricResponse(lrc: "[00:00.00]作词：作者", lrctrans: nil,
            qrc: "[0,1000]作词：作者(0,1000)", qrctrans: nil, qrcroma: nil)
        #expect(OrdinaryLyricParser.parse(response).isEmpty)
        #expect(OrdinaryLyricParser.parse(response, removeQRCInformation: false).count == 1)
        let lrcOnly = LyricResponse(lrc: "[00:00.00]正文", lrctrans: nil, qrc: "invalid", qrctrans: nil, qrcroma: nil)
        #expect(OrdinaryLyricParser.parse(lrcOnly).first?.text == "正文")
    }

    @Test func transitionLeadAppliesOnlyToActuallyParsedQRC() {
        let qrc = OrdinaryLyricParser.parseWithFormat(qrcResponse(["正文"]))
        #expect(qrc.format == .qrc)
        #expect(qrc.format.transitionLeadMs(configuredMs: 100) == 100)
        let fallback = OrdinaryLyricParser.parseWithFormat(.init(
            lrc: "[00:01.00]正文", lrctrans: nil, qrc: "invalid", qrctrans: nil, qrcroma: nil))
        #expect(fallback.format == .lrc)
        #expect(fallback.format.transitionLeadMs(configuredMs: 100) == 0)
        #expect(LyricFormat.ttml.transitionLeadMs(configuredMs: 100) == 0)
        #expect(LyricFormat.qrc.transitionLeadMs(configuredMs: 0) == 0)
    }

    @Test func qrcLongRepeatedRoleHeadersStaySafeAndPreserveUnknownSuffixes() {
        let repeated = String(repeating: "词曲", count: 500)
        let response = qrcResponse([repeated + "：作者", repeated + "x：歌词"])
        #expect(OrdinaryLyricParser.parse(response).map(\.text) == [repeated + "x：歌词"])
    }

    private func qrcResponse(_ texts: [String]) -> LyricResponse {
        let qrc = texts.enumerated().map { index, text in
            let start = 1_000 + index * 3_000
            return "[\(start),2000]\(text)(\(start),2000)"
        }.joined(separator: "\n")
        return .init(lrc: nil, lrctrans: nil, qrc: qrc,
            qrctrans: "[00:01.00]译一\n[00:04.00]//\n[00:07.00]译二",
            qrcroma: "[00:01.00]roma1\n[00:04.00]//\n[00:07.00]roma2")
    }

    @Test func websocketActionUsesExpectedJSONKeys() throws {
        let action = WSAction(
            action: "seek",
            userId: "session",
            user: nil,
            data: .init(currentTime: 12.5)
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
        #expect(object["action"] as? String == "seek")
        #expect(object["userId"] as? String == "session")
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["currentTime"] as? Double == 12.5)
    }

    @Test func precacheDownloadReportsFractionOnlyWhenTheLengthIsKnown() {
        #expect(audioDownloadFraction(receivedBytes: 512, expectedBytes: 2_048) == 0.25)
        #expect(audioDownloadFraction(receivedBytes: 4_096, expectedBytes: 2_048) == 1)
        // URLSession reports -1 for a response without a content length.
        #expect(audioDownloadFraction(receivedBytes: 512, expectedBytes: -1) == nil)
        #expect(audioDownloadFraction(receivedBytes: 0, expectedBytes: 0) == nil)
    }

    @Test func precacheStatusTextAlwaysAnnouncesDownloading() {
        #expect(audioDownloadStatusText(.init(songID: "a", receivedBytes: 512, expectedBytes: 2_048)) == "下载中 25%")
        #expect(audioDownloadStatusText(.init(songID: "a", receivedBytes: 512, expectedBytes: -1)) == "下载中")
        #expect(audioDownloadStatusText(.init(songID: "a")) == "下载中")
    }
}

@Suite struct MusicPlatformTests {
    @Test func sourceSurvivesPersistenceAndRoomTransfer() throws {
        let song = try JSONDecoder().decode(Song.self, from: Data(#"{"id":123,"name":"网易云歌曲","source":"netease"}"#.utf8))
        #expect(song.source == .netease)
        #expect(song.cacheKey != Song(id: "123", name: "QQ 歌曲").cacheKey)
        #expect(song.audioKey("exhigh") != song.audioKey("lossless"))
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        #expect(restored.source == .netease)
        let room = try JSONDecoder().decode(RoomSong.self, from: JSONEncoder().encode(RoomSong(song: song)))
        #expect(room.song.source == .netease)
        #expect(room.song.id == "123")
        let legacy = try JSONDecoder().decode(Song.self, from: Data(#"{"id":"123","name":"Old"}"#.utf8))
        #expect(legacy.source == .qq)
        let qq = try JSONDecoder().decode(Song.self, from: Data(#"{"id":"123","name":"QQ","source":"qqmusic"}"#.utf8))
        #expect(qq.source == .qq)
    }

    @Test func nativeYRCUsesAbsoluteWordTimesAndAlignedTranslation() {
        let response = LyricResponse(lrc: "[00:01.000]旧歌词", yrc: "[1000,1000](1000,400,0)你(1400,600,0)好", ytlrc: "[00:01.000]Hello", yromalrc: "[00:01.000]ni hao")
        let lines = OrdinaryLyricParser.parse(response)
        #expect(lines.count == 1)
        #expect(lines.first?.text == "你好")
        #expect(lines.first?.words.last?.startTime == 1400)
        #expect(lines.first?.words.last?.endTime == 2000)
        #expect(lines.first?.translatedLyric == "Hello")
        #expect(lines.first?.romanLyric == "ni hao")
    }
}

@Suite struct YRCSettingsTests {
    @Test func yrcUsesSharedInformationFilterAndTransitionLead() {
        let yrc = "[0,1000](0,1000,0)作词：作者\n[2000,1000](2000,400,0)你(2400,600,0)好\n[4000,1000](4000,1000,0)编曲：作者"
        let response = LyricResponse(yrc: yrc, ytlrc: "[00:02.000]Hello")
        let parsed = OrdinaryLyricParser.parseWithFormat(response)
        #expect(parsed.format == .yrc)
        #expect(parsed.format.transitionLeadMs(configuredMs: 250) == 250)
        #expect(parsed.lines.map(\.text) == ["你好"])
        #expect(parsed.lines.first?.translatedLyric == "Hello")
        #expect(parsed.lines.first?.words.first?.startTime == 2000)
        #expect(OrdinaryLyricParser.parse(response, removeQRCInformation: false).count == 3)
    }

    @Test func filteredYRCDoesNotRestoreMetadataFromLRC() {
        let result = OrdinaryLyricParser.parseWithFormat(.init(lrc: "[00:00.000]作曲：作者", yrc: "[0,1000](0,1000,0)作曲：作者"))
        #expect(result.format == .yrc)
        #expect(result.lines.isEmpty)
        let fallback = OrdinaryLyricParser.parseWithFormat(.init(lrc: "[00:01.000]正文", yrc: "invalid"))
        #expect(fallback.format == .lrc)
        #expect(fallback.format.transitionLeadMs(configuredMs: 250) == 0)
    }
}
