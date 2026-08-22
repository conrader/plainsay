import AVFoundation
import Foundation
import Network
import PlainsayCore

/// A small always-warm transcription server for the Mac Mini pilot: Parakeet
/// (via FluidAudio/CoreML, ANE-accelerated — same engine and code the Mac
/// client runs on-device) loaded once at startup, reused across requests.
///
/// No framework dependency deliberately: this needs to build on whatever
/// Swift toolchain happens to already be on the Mini, and pulling in Vapor's
/// dependency tree required a newer tools-version than was available there.
/// `Network.framework` + a hand-rolled HTTP/1.1 parser is a bounded amount of
/// code for the two routes this actually needs.
///
/// Wire shape deliberately mirrors the CT2 pilot server (`POST /transcribe`,
/// multipart field named `audio`, `GET /health`) so the two are directly
/// comparable and swappable in a benchmark or in api.plainsay.app's upstream
/// config later.

let port: NWEndpoint.Port = {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--port"), idx + 1 < args.count, let p = UInt16(args[idx + 1]) {
        return NWEndpoint.Port(rawValue: p) ?? 8098
    }
    return 8098
}()

// A process crash can bypass the per-request `defer` below. Keep uploads in a
// dedicated owner-only directory, remove any orphaned files before loading the
// model, and then recreate the directory before accepting traffic.
let audioTempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("plainsay-mini-transcribe", isDirectory: true)
try? FileManager.default.removeItem(at: audioTempDirectory)
try FileManager.default.createDirectory(
    at: audioTempDirectory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: NSNumber(value: 0o700)]
)
try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o700)],
    ofItemAtPath: audioTempDirectory.path
)

print("Loading Parakeet TDT 0.6B v3 (this compiles the CoreML model on first run)...")
let parakeet = ParakeetEngine(language: nil)
try await parakeet.prepare()
print("Parakeet ready. Listening on port \(port).")

let listener = try NWListener(using: .tcp, on: port)
listener.newConnectionHandler = { connection in
    connection.start(queue: .global())
    Task { await handle(connection) }
}
listener.start(queue: .global())

// Keep the process alive. `Duration.seconds(.infinity)` overflows converting
// to its internal representation, so loop a large finite sleep instead.
while true {
    try await Task.sleep(for: .seconds(3600))
}

// MARK: - Connection handling

func handle(_ connection: NWConnection) async {
    defer { connection.cancel() }
    guard let request = await readRequest(connection) else { return }

    switch (request.method, request.path) {
    case ("GET", "/health"):
        await respond(connection, status: 200, json: #"{"ok":true}"#)

    case ("POST", "/transcribe"):
        do {
            let response = try await transcribe(request: request)
            await respond(connection, status: 200, json: response)
        } catch let error as HTTPError {
            await respond(connection, status: error.status, json: #"{"error":"\#(error.message)"}"#)
        } catch {
            await respond(
                connection, status: 500,
                json: #"{"error":"\#(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))"}"#
            )
        }

    default:
        await respond(connection, status: 404, json: #"{"error":"not found"}"#)
    }
}

struct HTTPError: Error {
    let status: Int
    let message: String
}

struct ParsedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// Reads a full HTTP/1.1 request: headers, then exactly `Content-Length`
/// bytes of body. Audio clips here are a few seconds of 16kHz mono, at most a
/// few hundred KB — reading the whole thing into memory is fine.
func readRequest(_ connection: NWConnection) async -> ParsedRequest? {
    var buffer = Data()
    var headerEnd: Range<Data.Index>?

    while headerEnd == nil {
        guard let chunk = await receive(connection, max: 65536), !chunk.isEmpty else { return nil }
        buffer.append(chunk)
        headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        if buffer.count > 8192, headerEnd == nil { return nil }  // headers too large, malformed
    }

    guard let headerEnd else { return nil }
    let headerData = buffer[..<headerEnd.lowerBound]
    var bodyData = buffer[headerEnd.upperBound...]

    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    let path = String(parts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[key] = value
    }

    // Matches plainsay-server's own bodyLimit for the same kind of upload —
    // no cap here meant an attacker-declared Content-Length could make this
    // loop allocate without bound.
    let maxBodyBytes = 32 * 1024 * 1024
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    guard contentLength >= 0, contentLength <= maxBodyBytes else { return nil }
    while bodyData.count < contentLength {
        guard let chunk = await receive(connection, max: contentLength - bodyData.count), !chunk.isEmpty else {
            break
        }
        bodyData.append(chunk)
    }

    return ParsedRequest(method: method, path: path, headers: headers, body: Data(bodyData))
}

func receive(_ connection: NWConnection, max: Int) async -> Data? {
    await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
            if let error {
                _ = error
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: data)
        }
    }
}

func respond(_ connection: NWConnection, status: Int, json: String) async {
    let statusText = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 400 ? "Bad Request" : "Error"
    let body = Data(json.utf8)
    var head = "HTTP/1.1 \(status) \(statusText)\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var payload = Data(head.utf8)
    payload.append(body)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        connection.send(
            content: payload,
            completion: .contentProcessed { _ in continuation.resume() }
        )
    }
}

// MARK: - Multipart + transcription

struct AudioField {
    let data: Data
    /// The part's own declared filename, if any — used only to pick a
    /// matching temp-file extension so `AVAudioFile` gets a real container
    /// hint. Callers may upload WAV or AAC/m4a; without this, a bare
    /// extensionless temp file made `AVAudioFile` guess wrong for anything
    /// that wasn't WAV.
    let filename: String?
}

/// Extracts the `audio` file field from a `multipart/form-data` body given
/// the boundary from the request's Content-Type header.
func extractAudioField(request: ParsedRequest) throws -> AudioField {
    guard let contentType = request.headers["content-type"], contentType.contains("multipart/form-data") else {
        throw HTTPError(status: 400, message: "expected multipart/form-data")
    }
    guard let boundaryRange = contentType.range(of: "boundary=") else {
        throw HTTPError(status: 400, message: "missing multipart boundary")
    }
    let boundary = "--" + contentType[boundaryRange.upperBound...].trimmingCharacters(in: .init(charactersIn: "\""))
    let boundaryData = Data(boundary.utf8)

    let parts = request.body.components(separatedBy: boundaryData)
    for part in parts {
        guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let partHeaders = String(decoding: part[..<headerEnd.lowerBound], as: UTF8.self)
        guard partHeaders.contains("name=\"audio\"") else { continue }

        var content = part[headerEnd.upperBound...]
        // Strip the trailing "\r\n" that precedes the next boundary marker.
        if content.suffix(2) == Data("\r\n".utf8) {
            content = content.dropLast(2)
        }

        var filename: String?
        if let range = partHeaders.range(of: "filename=\"") {
            let rest = partHeaders[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                filename = String(rest[rest.startIndex..<end])
            }
        }

        return AudioField(data: Data(content), filename: filename)
    }
    throw HTTPError(status: 400, message: "no 'audio' field in multipart body")
}

/// The client-supplied filename's extension, restricted to a handful of
/// alphanumeric characters — long enough for "wav"/"m4a"/"mp4" and nothing
/// that could carry a "/", "..", or a null byte into a filesystem path.
func sanitizedExtension(from filename: String?) -> String {
    guard
        let filename, let dot = filename.lastIndex(of: "."),
        case let candidate = filename[filename.index(after: dot)...],
        !candidate.isEmpty, candidate.count <= 8,
        candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return ".wav" }
    return "." + candidate.lowercased()
}

func transcribe(request: ParsedRequest) async throws -> String {
    let field = try extractAudioField(request: request)
    guard !field.data.isEmpty else { throw HTTPError(status: 400, message: "empty audio upload") }

    // AVAudioFile picks its decoder from the file extension, so an
    // extensionless temp file guesses wrong for anything but WAV. Default to
    // .wav only when the upload genuinely didn't name itself. The extension
    // is client-supplied, so it's allowlisted to bare alphanumerics before
    // it ever touches a path — nothing that could smuggle a "/" or ".."
    // through `appendingPathComponent`.
    let ext = sanitizedExtension(from: field.filename)
    let tempURL = audioTempDirectory
        .appendingPathComponent("mini-transcribe-\(UUID().uuidString)\(ext)")
    try field.data.write(to: tempURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: tempURL.path
    )
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let samples = try loadSamples(fileURL: tempURL)
    guard !samples.isEmpty else { throw HTTPError(status: 400, message: "could not decode audio") }
    let duration = Double(samples.count) / whisperSampleRate

    let text = try await parakeet.transcribe(samples: samples, prompt: nil)
    let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"text":"\#(escapedText)","model":"parakeet-tdt-0.6b-v3","duration":\#(duration)}"#
}

/// Mirrors `BenchmarkCLI.loadSamples`: decode whatever audio container was
/// uploaded, resample to 16kHz mono Float32 — the format every
/// `TranscriptionEngine` expects.
func loadSamples(fileURL: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: fileURL)
    let sourceFormat = file.processingFormat
    guard
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
        )
    else {
        throw HTTPError(status: 500, message: "bad target format")
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        throw HTTPError(status: 500, message: "no converter")
    }

    // `file.length` is an Int64 read from the container's own header — a
    // small crafted file can declare a length near Int64.max, and
    // `AVAudioFrameCount(_:)` (a UInt32) traps rather than failing on a
    // value that doesn't fit. Reject before converting instead of crashing
    // the process; with launchd's KeepAlive that crash would otherwise
    // restart into a loop, re-running the CoreML model load every time.
    // 100M frames is already an order of magnitude past any real dictation
    // (~35 minutes even at 48kHz) and comfortably inside UInt32's range.
    let maxFrames: Int64 = 100_000_000
    guard file.length > 0, file.length <= maxFrames else {
        throw HTTPError(status: 400, message: "audio too long or invalid")
    }
    let frameCount = AVAudioFrameCount(file.length)
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
        throw HTTPError(status: 500, message: "no input buffer")
    }
    try file.read(into: inputBuffer)

    // Same overflow hazard as above, one step removed: bound the Double
    // before converting it back to a fixed-width frame count.
    let outCapacityRaw = (Double(frameCount) * whisperSampleRate / sourceFormat.sampleRate) + 1024
    guard outCapacityRaw.isFinite, outCapacityRaw <= Double(UInt32.max) else {
        throw HTTPError(status: 400, message: "audio too long or invalid")
    }
    let outCapacity = AVAudioFrameCount(outCapacityRaw)
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
        throw HTTPError(status: 500, message: "no output buffer")
    }

    var conversionError: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return inputBuffer
    }
    if let conversionError { throw conversionError }

    guard let channelData = outputBuffer.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
}

extension Data {
    /// Splits on every occurrence of `separator`, dropping the separator
    /// itself — a `Data`-native equivalent of `String.components(separatedBy:)`.
    func components(separatedBy separator: Data) -> [Data] {
        var result: [Data] = []
        var searchStart = startIndex
        while let range = self.range(of: separator, in: searchStart..<endIndex) {
            result.append(self[searchStart..<range.lowerBound])
            searchStart = range.upperBound
        }
        result.append(self[searchStart..<endIndex])
        return result
    }
}
