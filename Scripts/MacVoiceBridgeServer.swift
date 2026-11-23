#!/usr/bin/env swift
import AVFoundation
import Foundation
import Network

/// Lightweight macOS companion TTS bridge server (`http://127.0.0.1:8765`) for the iOS Simulator.
/// Exposes macOS's native Siri Natural (`com.apple.siri.natural.*`), Premium, and Enhanced
/// `AVSpeechSynthesisVoice` voices to the iOS Simulator over localhost HTTP as 48 kHz 16-bit PCM WAV audio.

struct BridgedVoiceDTO: Codable {
    let id: String
    let name: String
    let languageCode: String
    let qualityTier: String
    let subtitle: String
}

struct SynthesizeRequestDTO: Codable {
    let text: String
    let voiceID: String
}

private let excludedNoveltyNames: Set<String> = [
    "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos",
    "deranged", "fred", "good news", "hysterical", "jester", "junior",
    "kathy", "organ", "princess", "ralph", "superstar", "trinoids",
    "whisper", "wobble", "zarvox",
    "eddy", "flo", "grandma", "grandpa", "reed", "rocko", "sandy", "shelley"
]

private let preferredNames: [String] = [
    "siri", "nora", "samantha", "ava", "allison", "zoe", "nicky", "aaron",
    "evan", "nathan", "daniel", "martha", "arthur", "karen", "moira", "tessa"
]

@MainActor
func listMacVoices() -> [BridgedVoiceDTO] {
    var allVoices = AVSpeechSynthesisVoice.speechVoices()

    let knownSiriIdentifiers = [
        "com.apple.siri.natural.Nora",
        "com.apple.siri.natural.Aaron",
        "com.apple.siri.natural.Simone",
        "com.apple.siri.natural.Damon"
    ]
    for siriID in knownSiriIdentifiers {
        if !allVoices.contains(where: { $0.identifier == siriID }),
           let siriVoice = AVSpeechSynthesisVoice(identifier: siriID) {
            allVoices.append(siriVoice)
        }
    }

    let filtered = allVoices.filter { voice in
        if voice.voiceTraits.contains(.isNoveltyVoice) { return false }
        let idLower = voice.identifier.lowercased()
        if idLower.contains("speech.synthesis.voice") || idLower.contains("eloquence") {
            return false
        }
        if excludedNoveltyNames.contains(voice.name.lowercased()) {
            return false
        }
        if idLower.contains("super-compact") {
            let hasBetterSibling = allVoices.contains { other in
                other.identifier != voice.identifier &&
                other.name == voice.name &&
                other.language == voice.language &&
                !other.identifier.lowercased().contains("super-compact")
            }
            if hasBetterSibling { return false }
        }
        return true
    }

    let mapped = filtered.map { voice -> BridgedVoiceDTO in
        let idLower = voice.identifier.lowercased()
        let isSiri = idLower.contains("siri")
        let tier: String
        switch voice.quality {
        case .premium:
            tier = "Premium"
        case .enhanced:
            tier = "Enhanced"
        default:
            tier = isSiri ? "Enhanced" : "Standard"
        }

        let displayName: String
        if isSiri {
            let suffix = voice.identifier.components(separatedBy: ".").last ?? voice.name
            if voice.name.lowercased().hasPrefix("voice ") && !suffix.lowercased().hasPrefix("voice") {
                displayName = "Siri \(suffix) (\(voice.name))"
            } else if !voice.name.lowercased().contains("siri") {
                displayName = "Siri \(voice.name)"
            } else {
                displayName = voice.name
            }
        } else {
            displayName = voice.name
        }

        let localeName = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let subtitle = isSiri ? "Mac Siri Natural • \(localeName)" : "Mac On-Device • \(localeName)"

        return BridgedVoiceDTO(
            id: voice.identifier,
            name: displayName,
            languageCode: voice.language,
            qualityTier: tier,
            subtitle: subtitle
        )
    }

    return mapped.sorted { lhs, rhs in
        let lhsEn = lhs.languageCode.lowercased().hasPrefix("en")
        let rhsEn = rhs.languageCode.lowercased().hasPrefix("en")
        if lhsEn != rhsEn { return lhsEn }

        let lhsSiri = lhs.id.lowercased().contains("siri")
        let rhsSiri = rhs.id.lowercased().contains("siri")
        if lhsSiri != rhsSiri { return lhsSiri }

        let rankMap = ["Premium": 3, "Enhanced": 2, "Standard": 1]
        let lhsQ = rankMap[lhs.qualityTier] ?? 0
        let rhsQ = rankMap[rhs.qualityTier] ?? 0
        if lhsQ != rhsQ { return lhsQ > rhsQ }

        let lhsUS = (lhs.languageCode.lowercased() == "en-us")
        let rhsUS = (rhs.languageCode.lowercased() == "en-us")
        if lhsUS != rhsUS { return lhsUS }

        let lhsRank = preferredNames.firstIndex(where: { lhs.name.lowercased().contains($0) }) ?? Int.max
        let rhsRank = preferredNames.firstIndex(where: { rhs.name.lowercased().contains($0) }) ?? Int.max
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// Retains active `AVSpeechSynthesizer` instances while asynchronous `write(_:)` buffer callbacks are streaming.
@MainActor
private var activeSynthesizers: [UUID: AVSpeechSynthesizer] = [:]

/// Synthesizes `text` using macOS `AVSpeechSynthesizer.write(_:)` asynchronously on the main queue
/// and invokes `completion` with a 48 kHz 16-bit PCM WAV file in ~150ms.
@MainActor
func synthesizeToWAVData(
    text: String,
    voiceID: String,
    completion: @escaping @Sendable (Data?) -> Void
) {
    let jobID = UUID()
    let synthesizer = AVSpeechSynthesizer()
    activeSynthesizers[jobID] = synthesizer

    let utterance = AVSpeechUtterance(string: text)
    if let matched = AVSpeechSynthesisVoice(identifier: voiceID) {
        utterance.voice = matched
    } else if let siriNora = AVSpeechSynthesisVoice(identifier: "com.apple.siri.natural.Nora") {
        utterance.voice = siriNora
    } else {
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    }

    utterance.rate = 0.49

    var floatSamples: [Float] = []
    var sampleRate: UInt32 = 48000
    var hasCompleted = false

    let finish: (Data?) -> Void = { data in
        guard !hasCompleted else { return }
        hasCompleted = true
        activeSynthesizers.removeValue(forKey: jobID)
        completion(data)
    }

    synthesizer.write(utterance) { buffer in
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            let wav = floatSamples.isEmpty ? nil : encodePCM16WAV(samples: floatSamples, sampleRate: sampleRate)
            finish(wav)
            return
        }

        if pcmBuffer.frameLength == 0 {
            let wav = floatSamples.isEmpty ? nil : encodePCM16WAV(samples: floatSamples, sampleRate: sampleRate)
            finish(wav)
            return
        }

        sampleRate = UInt32(pcmBuffer.format.sampleRate)
        let frameCount = Int(pcmBuffer.frameLength)

        if let floatChannelData = pcmBuffer.floatChannelData {
            let channel0 = floatChannelData[0]
            for i in 0..<frameCount {
                floatSamples.append(channel0[i])
            }
        } else if let int16ChannelData = pcmBuffer.int16ChannelData {
            let channel0 = int16ChannelData[0]
            for i in 0..<frameCount {
                floatSamples.append(Float(channel0[i]) / Float(Int16.max))
            }
        }
    }

    // Safety timeout after 15s
    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
        if !hasCompleted {
            let wav = floatSamples.isEmpty ? nil : encodePCM16WAV(samples: floatSamples, sampleRate: sampleRate)
            finish(wav)
        }
    }
}

func encodePCM16WAV(samples: [Float], sampleRate: UInt32) -> Data {
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
    let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
    let dataSize: UInt32 = UInt32(samples.count * 2)
    let chunkSize: UInt32 = 36 + dataSize

    var wav = Data(capacity: Int(44 + dataSize))
    wav.append(contentsOf: "RIFF".utf8)
    withUnsafeBytes(of: chunkSize.littleEndian) { wav.append(contentsOf: $0) }
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    let subchunk1Size: UInt32 = 16
    let audioFormat: UInt16 = 1 // PCM
    withUnsafeBytes(of: subchunk1Size.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: audioFormat.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: numChannels.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: sampleRate.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: byteRate.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: blockAlign.littleEndian) { wav.append(contentsOf: $0) }
    withUnsafeBytes(of: bitsPerSample.littleEndian) { wav.append(contentsOf: $0) }
    wav.append(contentsOf: "data".utf8)
    withUnsafeBytes(of: dataSize.littleEndian) { wav.append(contentsOf: $0) }

    var pcm16 = [Int16](repeating: 0, count: samples.count)
    for i in 0..<samples.count {
        let clamped = max(-1.0, min(1.0, samples[i]))
        pcm16[i] = Int16(clamped * Float(Int16.max)).littleEndian
    }
    pcm16.withUnsafeBufferPointer { ptr in
        wav.append(UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr.baseAddress)?.assumingMemoryBound(to: UInt8.self),
            count: samples.count * 2
        ))
    }

    return wav
}

// MARK: - Minimal HTTP Server on 127.0.0.1:8765

final class MacVoiceBridgeHTTPServer: @unchecked Sendable {
    private let port: NWEndpoint.Port = 8765
    private var listener: NWListener?

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[MacVoiceBridge] Listening on http://127.0.0.1:8765 (Siri & Enhanced Mac Voices ready)")
                fflush(stdout)
            case .failed(let error):
                print("[MacVoiceBridge] Listener failed: \(error)")
                fflush(stdout)
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveFullHTTPRequest(on: connection, accumulated: Data())
    }

    private func receiveFullHTTPRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let expectedContentLength = Self.parseContentLength(from: headerString)
                let currentBodyLength = buffer.count - headerEndRange.upperBound

                if currentBodyLength >= expectedContentLength || isComplete {
                    let bodyData = buffer.subdata(in: headerEndRange.upperBound..<min(buffer.count, headerEndRange.upperBound + expectedContentLength))
                    self.routeHTTPRequest(headerString: headerString, bodyData: bodyData, connection: connection)
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveFullHTTPRequest(on: connection, accumulated: buffer)
        }
    }

    private static func parseContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func routeHTTPRequest(headerString: String, bodyData: Data, connection: NWConnection) {
        let firstLine = headerString.components(separatedBy: "\r\n").first ?? ""
        let components = firstLine.split(separator: " ")
        let method = components.first.map(String.init) ?? "GET"
        let path = components.dropFirst().first.map(String.init) ?? "/"

        if method == "GET" && path.hasPrefix("/health") {
            let body = Data("{\"status\":\"ok\"}".utf8)
            sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: body)
            return
        }

        if method == "GET" && path.hasPrefix("/voices") {
            DispatchQueue.main.async {
                let voices = listMacVoices()
                let json = (try? JSONEncoder().encode(voices)) ?? Data("[]".utf8)
                self.sendHTTPResponse(connection: connection, status: "200 OK", contentType: "application/json", body: json)
            }
            return
        }

        if method == "POST" && path.hasPrefix("/synthesize") {
            guard let requestDTO = try? JSONDecoder().decode(SynthesizeRequestDTO.self, from: bodyData),
                  !requestDTO.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sendHTTPResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain", body: Data("Invalid request payload".utf8))
                return
            }

            DispatchQueue.main.async {
                synthesizeToWAVData(text: requestDTO.text, voiceID: requestDTO.voiceID) { wavData in
                    if let wavData {
                        self.sendHTTPResponse(connection: connection, status: "200 OK", contentType: "audio/wav", body: wavData)
                    } else {
                        self.sendHTTPResponse(connection: connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data("Synthesis failed".utf8))
                    }
                }
            }
            return
        }

        sendHTTPResponse(connection: connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
    }

    private func sendHTTPResponse(connection: NWConnection, status: String, contentType: String, body: Data) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var payload = Data(headers.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// Warm up AVSpeechSynthesisVoice catalog on the main RunLoop so UnifiedAssetFramework registers Siri Natural voices
_ = AVSpeechSynthesisVoice.speechVoices()
_ = AVSpeechSynthesisVoice(identifier: "com.apple.siri.natural.Nora")
RunLoop.main.run(until: Date().addingTimeInterval(0.35))

let server = MacVoiceBridgeHTTPServer()
try server.start()
RunLoop.main.run()
