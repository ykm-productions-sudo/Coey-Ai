import Foundation

enum ElevenLabsError: LocalizedError {
    case refused
    case notFound
    case didNotSpeak
    case badResponse

    var errorDescription: String? {
        switch self {
        case .refused: return "That API key was refused."
        case .notFound: return "That voice id was not found."
        case .didNotSpeak: return "ElevenLabs did not speak."
        case .badResponse: return "ElevenLabs sent an unexpected response."
        }
    }
}

/// Minimal ElevenLabs client. Requests run natively so the WebView never
/// has to deal with CORS, and playback uses AVAudioPlayer (no autoplay
/// restrictions).
enum ElevenLabsClient {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    static func voiceName(apiKey: String, voiceId: String) async throws -> String {
        guard let encoded = voiceId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let url = URL(string: "https://api.elevenlabs.io/v1/voices/\(encoded)") else {
            throw ElevenLabsError.notFound
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ElevenLabsError.badResponse
        }
        if http.statusCode == 401 { throw ElevenLabsError.refused }
        guard (200..<300).contains(http.statusCode) else {
            throw ElevenLabsError.notFound
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ElevenLabsError.badResponse
        }
        return (json["name"] as? String) ?? "ElevenLabs"
    }

    static func speech(apiKey: String, voiceId: String, text: String) async throws -> Data {
        guard let encoded = voiceId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(encoded)") else {
            throw ElevenLabsError.notFound
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.45,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ElevenLabsError.badResponse
        }
        if http.statusCode == 401 { throw ElevenLabsError.refused }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw ElevenLabsError.didNotSpeak
        }
        return data
    }
}
