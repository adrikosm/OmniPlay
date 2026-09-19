import Foundation
import MediaCompat
import Testing
import TestSupport

@Suite("Media probe")
struct MediaProbeTests {
    private func probe(_ rel: String) -> MediaProbeResult { MediaProbe.probe(Fixtures.url("mv-basic/www/\(rel)"), relativePath: rel) }

    @Test("Fixture media identify by header: WebM VP9/Vorbis, MP4 H.264/AAC, moov at end, Ogg Vorbis, M4A, MP3, WAV, MIDI")
    func fixtures() {
        let webm = probe("movies/intro.webm")
        #expect(webm.container == .webm && webm.video == .vp9 && webm.audio == .vorbis)
        let mp4 = probe("movies/intro.mp4")
        #expect(mp4.container == .mp4 && mp4.video == .h264 && mp4.audio == .aac)
        let outro = probe("movies/outro.mp4")
        #expect(outro.container == .mp4 && outro.video == .h264 && outro.audio == .aac)
        let ogg = probe("audio/bgm/a.ogg")
        #expect(ogg.container == .ogg && ogg.audio == .vorbis && ogg.video == nil)
        let m4a = probe("audio/bgm/a.m4a")
        #expect(m4a.container == .m4a && m4a.audio == .aac)
        #expect(probe("audio/me/fanfare.mp3").container == .mp3)
        #expect(probe("audio/se/hit.wav").audio == .pcm)
        #expect(probe("audio/bgm/town.mid").container == .midi)
        #expect(probe("img/characters/Actor1.png").container == .unknown)
        #expect(webm.bytes > 0)
    }

    @Test("Corrupt or empty data never throws")
    func corrupt() {
        #expect(MediaProbe.identify(Data(), path: "x").container == .unknown)
        #expect(MediaProbe.identify(Data([0x1A, 0x45, 0xDF, 0xA3, 0xFF, 0xFF]), path: "x").container == .webm)
        #expect(MediaProbe.identify(Data([0, 0, 0, 8]) + Data("ftyp".utf8), path: "x").container == .mp4)
        #expect(MediaProbe.identify(Data("OggS".utf8) + Data(count: 10), path: "x").container == .ogg)
    }
}
