import MediaCompat
import Testing

@Suite("MediaCompat")
struct MediaCompatTests {
    @Test("Probe results round-trip")
    func probeHashable() {
        let a = MediaProbeResult(path: "movies/op.webm", container: .webm, video: .vp9, audio: .vorbis)
        let b = MediaProbeResult(path: "movies/op.webm", container: .webm, video: .vp9, audio: .vorbis)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }
}
