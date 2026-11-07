import Foundation
import UIKit
import WebKit
import AVFoundation

/// Receives `window.webkit.messageHandlers.coey.postMessage(...)` calls.
final class BridgeController: NSObject, WKScriptMessageHandler {

    weak var webView: WKWebView?

    private var players: [Int: AVAudioPlayer] = [:]
    private let speech = SpeechController()

    // MARK: - Messages

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let command = body["cmd"] as? String else {
            return
        }

        let id = (body["id"] as? NSNumber)?.intValue ?? 0

        switch command {
        case "model.status":
            send(id: id, type: "done", data: ["loaded": LlamaEngine.shared.isLoaded])

        case "model.load":
            loadModel(body: body, id: id)

        case "model.unload":
            LlamaEngine.shared.unload()
            send(id: id, type: "done", data: ["loaded": false])

        case "chat.start":
            startChat(body: body, id: id)

        case "chat.abort":
            LlamaEngine.shared.abort()

        case "voice.name":
            voiceName(body: body, id: id)

        case "voice.speak":
            speak(body: body, id: id)

        case "voice.stop":
            stopVoices()

        case "speech.start":
            let language = body["lang"] as? String ?? "en-US"
            speech.start(language: language) { [weak self] name, payload in
                self?.send(id: id, type: "event", data: payload)
            }

        case "speech.stop":
            speech.stop(notify: false)

        case "open.url":
            if let raw = body["url"] as? String,
               let url = URL(string: raw),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }

        default:
            send(
                id: id,
                type: "error",
                data: ["message": "Unknown native command: \(command)"]
            )
        }
    }

    // MARK: - Model

    private func loadModel(body: [String: Any], id: Int) {
        guard let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              let fileName = body["file"] as? String, !fileName.isEmpty else {
            send(id: id, type: "error", data: ["message": "The model address is invalid."])
            return
        }

        let expected = (body["expectedBytes"] as? NSNumber)?.int64Value ?? 0
        let nCtx = (body["nCtx"] as? NSNumber)?.intValue ?? 2048
        let nThreads = (body["nThreads"] as? NSNumber)?.intValue ?? 4
        let nBatch = (body["nBatch"] as? NSNumber)?.intValue ?? 128

        UIApplication.shared.isIdleTimerDisabled = true

        ModelStore.shared.download(
            fileName: fileName,
            from: url,
            expectedBytes: expected,
            progress: { [weak self] loaded, total in
                self?.send(
                    id: id,
                    type: "progress",
                    data: ["loaded": loaded, "total": total]
                )
            },
            completion: { [weak self] result in
                switch result {
                case .success(let localURL):
                    LlamaEngine.shared.load(
                        path: localURL.path,
                        nCtx: nCtx,
                        nThreads: nThreads,
                        nBatch: nBatch
                    ) { loadResult in
                        UIApplication.shared.isIdleTimerDisabled = false
                        switch loadResult {
                        case .success:
                            self?.send(id: id, type: "done", data: ["loaded": true])
                        case .failure(let error):
                            self?.send(
                                id: id,
                                type: "error",
                                data: ["message": error.localizedDescription]
                            )
                        }
                    }

                case .failure(let error):
                    UIApplication.shared.isIdleTimerDisabled = false
                    self?.send(
                        id: id,
                        type: "error",
                        data: ["message": error.localizedDescription]
                    )
                }
            }
        )
    }

    // MARK: - Chat

    private func startChat(body: [String: Any], id: Int) {
        let ref = body["ref"] as? String ?? ""
        let rawMessages = body["messages"] as? [[String: Any]] ?? []

        let messages: [ChatTurn] = rawMessages.compactMap { entry in
            guard let role = entry["role"] as? String,
                  let content = entry["content"] as? String else {
                return nil
            }
            return ChatTurn(role: role, content: content)
        }

        guard !messages.isEmpty else {
            send(id: id, type: "error", data: ["message": "There is nothing to answer."])
            return
        }

        var options = GenerationOptions()
        options.temperature = floatValue(body["temperature"], fallback: 0.8)
        options.topP = floatValue(body["topP"], fallback: 0.95)
        options.topK = Int32((body["topK"] as? NSNumber)?.intValue ?? 40)
        options.repeatPenalty = floatValue(body["repeatPenalty"], fallback: 1.1)
        options.maxTokens = (body["maxTokens"] as? NSNumber)?.intValue ?? 256

        var collected = ""

        LlamaEngine.shared.generate(
            messages: messages,
            options: options,
            onToken: { [weak self] piece in
                collected += piece
                self?.send(
                    id: id,
                    type: "token",
                    data: ["token": piece, "ref": ref]
                )
            },
            completion: { [weak self] result in
                switch result {
                case .success:
                    self?.send(
                        id: id,
                        type: "done",
                        data: ["text": collected, "ref": ref]
                    )
                case .failure(let error):
                    self?.send(
                        id: id,
                        type: "error",
                        data: ["message": error.localizedDescription]
                    )
                }
            }
        )
    }

    private func floatValue(_ value: Any?, fallback: Float) -> Float {
        if let number = value as? NSNumber { return number.floatValue }
        return fallback
    }

    // MARK: - Voice

    private func voiceName(body: [String: Any], id: Int) {
        guard let apiKey = body["apiKey"] as? String,
              let voiceId = body["voiceId"] as? String else {
            send(id: id, type: "error", data: ["message": "Missing ElevenLabs details."])
            return
        }

        Task { @MainActor in
            do {
                let name = try await ElevenLabsClient.voiceName(
                    apiKey: apiKey,
                    voiceId: voiceId
                )
                self.send(id: id, type: "done", data: ["name": name])
            } catch {
                self.send(
                    id: id,
                    type: "error",
                    data: ["message": error.localizedDescription]
                )
            }
        }
    }

    private func speak(body: [String: Any], id: Int) {
        guard let apiKey = body["apiKey"] as? String,
              let voiceId = body["voiceId"] as? String,
              let text = body["text"] as? String, !text.isEmpty else {
            send(id: id, type: "error", data: ["message": "There is nothing to say."])
            return
        }

        stopVoices()

        Task { @MainActor in
            do {
                let audio = try await ElevenLabsClient.speech(
                    apiKey: apiKey,
                    voiceId: voiceId,
                    text: text
                )
                try self.play(audio: audio, id: id)
                self.send(id: id, type: "done", data: ["queued": true])
            } catch {
                self.send(
                    id: id,
                    type: "error",
                    data: ["message": error.localizedDescription]
                )
            }
        }
    }

    private func play(audio: Data, id: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coey-voice", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileURL = directory.appendingPathComponent("line-\(id).mp3")
        try audio.write(to: fileURL, options: .atomic)

        let player = try AVAudioPlayer(contentsOf: fileURL)
        player.delegate = self
        player.prepareToPlay()
        players[id] = player
        player.play()
    }

    private func stopVoices() {
        for (_, player) in players {
            player.stop()
        }
        players.removeAll()
    }

    // MARK: - Sending to JavaScript

    private func send(id: Int, type: String, data: [String: Any]) {
        var payload = data
        payload["id"] = id
        payload["type"] = type

        guard JSONSerialization.isValidJSONObject(payload),
              let JSONData = try? JSONSerialization.data(withJSONObject: payload),
              let JSONString = String(data: JSONData, encoding: .utf8) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.__coeyNative(\(JSONString));",
                completionHandler: nil
            )
        }
    }
}

extension BridgeController: AVAudioPlayerDelegate {

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let entry = self.players.first(where: { $0.value === player }) else {
                return
            }
            self.players.removeValue(forKey: entry.key)
            self.send(id: entry.key, type: "event", data: ["name": "ended"])
        }
    }
}
