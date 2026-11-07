import Foundation
import AVFoundation
import Speech

/// Bridges SFSpeechRecognizer to the WebView's SpeechRecognition calls.
/// The web bundle polls `window.webkitSpeechRecognition`; native-bridge.js
/// installs a shim that talks to this class.
final class SpeechController {

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var onEvent: ((String, [String: Any]) -> Void)?
    private var running = false

    func start(
        language: String,
        onEvent: @escaping (String, [String: Any]) -> Void
    ) {
        stop(notify: false)
        self.onEvent = onEvent

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self.emit("speechError", [
                        "message": "Speech recognition is off. Allow it in Settings."
                    ])
                }
                return
            }

            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self.emit("speechError", [
                            "message": "The microphone is off. Allow it in Settings."
                        ])
                        return
                    }
                    self.begin(language: language)
                }
            }
        }
    }

    private func begin(language: String) {
        guard !running else { return }

        let locale = Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            emit("speechError", [
                "message": "The speech service is not available right now."
            ])
            return
        }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            emit("speechError", ["message": "The microphone did not open."])
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            emit("speechError", ["message": "The microphone did not open."])
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            emit("speechError", ["message": "The microphone did not open."])
            return
        }

        self.engine = engine
        self.running = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.running else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    self.emit("speech", ["transcript": text, "final": result.isFinal])
                }
                if result.isFinal {
                    DispatchQueue.main.async { self.stop(notify: true) }
                    return
                }
            }

            if error != nil {
                DispatchQueue.main.async { self.stop(notify: true) }
            }
        }
    }

    func stop(notify: Bool) {
        guard running || task != nil else {
            if notify { emit("speechEnd", [:]) }
            return
        }

        running = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        recognizer = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        if notify {
            emit("speechEnd", [:])
        }
    }

    private func emit(_ name: String, _ payload: [String: Any]) {
        guard let onEvent else { return }
        var data = payload
        data["name"] = name
        DispatchQueue.main.async {
            onEvent(name, data)
        }
    }
}
