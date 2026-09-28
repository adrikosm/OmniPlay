import COggVorbis
import CryptoKit
import Diagnostics
import Foundation
import GameCore
import LocalGameServer

/// Decodes Ogg Vorbis for the web runtime. WebKit on iOS decodes Opus, MP3, AAC, WAV and FLAC, but not Vorbis in an
/// Ogg file, in either `<audio>` or WebAudio. RPG Maker MV ships every sound that way and many HTML5 games do too.
/// The page sends the bytes it would have decoded (`omniplay-audio.js`, POST) or asks for a file's decoded form
/// (`?omniplay=pcm`); this returns 16-bit PCM WAV, cached per game by content, so each sound is decoded once.
public actor OggVorbisDecoder {
    public static let postPath = "/__omniplay/decode-audio"
    /// Forty minutes of 48 kHz stereo; anything longer is not a game sound.
    public static let maxOutputBytes: Int64 = 460 << 20

    public enum Failure: Error, CustomStringConvertible {
        case notVorbis
        case damaged(Int32)
        case tooLong

        public var description: String {
            switch self {
            case .notVorbis: "not an Ogg Vorbis stream"
            case let .damaged(code): "damaged Ogg Vorbis stream (\(code))"
            case .tooLong: "decoded audio would exceed \(OggVorbisDecoder.maxOutputBytes >> 20) MiB"
            }
        }
    }

    private let directory: URL
    private let session: SessionID?
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(cacheDirectory: URL, session: SessionID?) {
        directory = cacheDirectory.appending(path: "decoded-audio", directoryHint: .isDirectory)
        self.session = session
    }

    /// True for an Ogg stream whose first packet is a Vorbis identification header ("OggS", then 0x01 "vorbis").
    public nonisolated static func isOggVorbis(_ head: Data) -> Bool {
        guard head.count >= 35 else { return false }
        let b = [UInt8](head.prefix(35))
        return b[0 ..< 4] == [0x4F, 0x67, 0x67, 0x53] && b[28] == 0x01 && b[29 ..< 35] == Array("vorbis".utf8)[...]
    }

    /// The POST route: the request body is the game's bytes.
    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        do {
            let key = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
            let body = request.body
            let url = try await decoded(key: key) { try body }
            return Self.fileResponse(url)
        } catch {
            OPLog.log(.web, .default, "audio decode refused: \(error)", session: session)
            return .text(422, "\(error)")
        }
    }

    /// The `?omniplay=pcm` transform: the decoded form of a file on disk, or nil to serve it unchanged.
    public func transform(_ file: URL) async -> (url: URL, mime: String)? {
        guard let head = try? Self.head(of: file), Self.isOggVorbis(head) else { return nil }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let stamp = "\(file.path(percentEncoded: false))|\(values?.fileSize ?? 0)|\(modified)"
        let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
        do {
            return try await (decoded(key: key) { try SmallFileGuard.read(file, maxBytes: HTTPRequestParser.bodyCap) }, "audio/wav")
        } catch {
            OPLog.log(.web, .default, "audio decode of \(file.lastPathComponent) failed: \(error)", session: session)
            return nil
        }
    }

    private func decoded(key: String, input: @escaping @Sendable () throws -> Data) async throws -> URL {
        let out = directory.appending(path: key + ".wav")
        if FileManager.default.fileExists(atPath: out.path(percentEncoded: false)) {
            return out
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let directory = directory
        let task = Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let started = ContinuousClock.now
            let data = try input()
            try Self.decode(data, to: out)
            return (out, started.duration(to: .now))
        }
        inFlight[key] = Task { try await task.value.0 }
        defer { inFlight[key] = nil }
        let (url, took) = try await task.value
        OPLog.log(.web, .debug, "decoded Ogg Vorbis \(key.prefix(8)) in \(took)", session: session)
        return url
    }

    /// Streams PCM into a WAV file, writing the header last once the sizes are known. A partial file never stays.
    nonisolated static func decode(_ data: Data, to url: URL) throws {
        guard isOggVorbis(data.prefix(64)) else { throw Failure.notVorbis }
        let partial = url.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var finished = false
        defer {
            try? handle.close()
            if !finished {
                try? FileManager.default.removeItem(at: partial)
            }
        }
        try handle.write(contentsOf: Data(count: 44))
        final class Sink { var handle: FileHandle; var written: Int64 = 0; var failed = false; init(_ h: FileHandle) { handle = h } }
        let sink = Sink(handle)
        var rate: Int32 = 0, channels: Int32 = 0
        let status = data.withUnsafeBytes { raw -> Int32 in
            op_vorbis_decode(
                raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                { context, pcm, bytes in
                    let sink = Unmanaged<Sink>.fromOpaque(context!).takeUnretainedValue()
                    sink.written += Int64(bytes)
                    guard sink.written <= OggVorbisDecoder.maxOutputBytes, let pcm else { return 1 }
                    do { try sink.handle.write(contentsOf: Data(bytes: pcm, count: bytes)) } catch { sink.failed = true; return 1 }
                    return 0
                },
                Unmanaged.passUnretained(sink).toOpaque(), &rate, &channels
            )
        }
        switch status {
        case 0: break
        case -1: throw Failure.notVorbis
        case -3 where !sink.failed: throw Failure.tooLong
        default: throw Failure.damaged(status)
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(dataBytes: UInt32(sink.written), rate: UInt32(rate), channels: UInt16(channels)))
        try handle.close()
        try FileManager.default.moveItem(at: partial, to: url)
        finished = true
    }

    nonisolated static func wavHeader(dataBytes: UInt32, rate: UInt32, channels: UInt16) -> Data {
        var d = Data()
        func put(_ v: some FixedWidthInteger) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) &+ dataBytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(channels); put(rate); put(rate * UInt32(channels) * 2); put(channels * 2); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(dataBytes)
        return d
    }

    nonisolated static func head(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: 64) ?? Data()
    }

    nonisolated static func fileResponse(_ url: URL) -> HTTPResponse {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return HTTPResponse(status: 200, headers: [("Content-Type", "audio/wav")], body: .file(url, range: nil, totalSize: size))
    }
}
