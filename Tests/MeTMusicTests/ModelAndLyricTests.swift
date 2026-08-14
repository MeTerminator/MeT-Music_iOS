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
        #expect(playerArtworkSide(in: portrait) == 320)

        let landscape = CGSize(width: 874, height: 402)
        let landscapeSide = playerArtworkSide(in: landscape)
        #expect(landscapeSide <= landscape.width * 0.8)
        #expect(landscapeSide <= landscape.height * 0.48)

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

    @Test func qrcInformationRemovalMatchesAndroidBehavior() {
        let qrc = """
        [0,1000]标题(0,500)：测试(500,500)
        [1000,1000]作词(1000,500)：某人(1500,500)
        [2000,1000]正文(2000,1000)
        """
        let response = LyricResponse(lrc: nil, lrctrans: nil, qrc: qrc, qrctrans: nil, qrcroma: nil)
        #expect(OrdinaryLyricParser.parse(response, removeQRCInformation: false).count == 3)
        let filtered = OrdinaryLyricParser.parse(response, removeQRCInformation: true)
        #expect(filtered.count == 1)
        #expect(filtered[0].text == "正文")
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
}
