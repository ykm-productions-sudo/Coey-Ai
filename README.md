# Coey Ai — iOS build 64

Native iOS port of the existing Android app. **Android build 63 stays as it is**; this is the
iOS counterpart, versioned `1.0 (64)`.

The Android app is a WebView shell around a React bundle plus a JNI llama.cpp engine.
This port keeps the same bundle and replaces the native half with Swift:

| Android | iOS |
| --- | --- |
| `WebView` + `assets/index.html` | `WKWebView` served from a loopback HTTP server |
| `native-bridge.js` → `@JavascriptInterface` | `native-bridge.js` → `WKScriptMessageHandler("coey")` |
| llama.cpp via JNI + `llama.android` | `llama.xcframework` (`v0.9.0`) + Swift `LlamaEngine` |
| Model in app storage, downloaded once | Same: 398 MB Q4_K_M fetched from Hugging Face on first run |
| ElevenLabs via native player | `URLSession` + `AVAudioPlayer` |
| Android `SpeechRecognizer` | `SFSpeechRecognizer` shim for `webkitSpeechRecognition` |
| `avatarTalk.webm` / `avatarIdle.webm` | Re-encoded H.264 `avatarTalk.mp4` / `avatarIdle.mp4` |
| PIN, chats, keys in `localStorage` | Same, served over `http://127.0.0.1:8765` so storage persists |

## Layout

```
CoeyAi-iOS/
  project.yml                 XcodeGen project definition (version 64)
  codemagic.yaml              cloud build → TestFlight
  CoeyAi/
    App/CoeyApp.swift         SwiftUI entry point, audio session
    App/WebHostController.swift   WKWebView host, downloads, permissions
    Engine/LlamaEngine.swift  llama.cpp chat loop (chat template, sampling)
    Engine/ModelStore.swift   first-run GGUF download
    Net/LocalHTTPServer.swift loopback asset server (storage + video ranges)
    Voice/BridgeController.swift  JS ↔ native command router
    Voice/ElevenLabs.swift    voice lookup + TTS
    Voice/SpeechController.swift  speech-to-text
    Resources/                index.html, native-bridge.js, media/
    Assets.xcassets/          app icon, launch colour
    Info.plist
  scripts/build_llama.sh      builds Frameworks/llama.xcframework
```

## What you need

1. An Apple Developer Program membership (TestFlight / App Store install).
2. A Git host (GitHub, GitLab, Bitbucket) and a Codemagic account for the cloud build.
   A Mac with Xcode 15+ also works.

There is no way around this: iOS builds must be signed by Apple. Linux cannot produce an
installable `.ipa`.

## Build in the cloud (no Mac)

1. Push this folder to a repository (branch `main`).
2. In Codemagic: **Add application** → connect the repo → it picks up `codemagic.yaml`.
3. Create an App Store Connect API key and save it as a Codemagic integration named
   **`CoeyASC`** (Teams → Integrations). The `ios_signing` block uses it to fetch the
   distribution certificate and provisioning profile for `ai.coey.app`.
4. Change the bundle id in `project.yml`, `codemagic.yaml` and `CoeyAi/Info.plist` if
   `ai.coey.app` is not yours, then start the `coey-ios-64` workflow.
5. The workflow builds `llama.xcframework`, generates the Xcode project, archives build 64
   and uploads it to TestFlight for the Internal group.

## Build on a Mac

```bash
brew install xcodegen cmake
./scripts/build_llama.sh          # adds Frameworks/llama.xcframework
xcodegen generate
open CoeyAi.xcodeproj
```

Select your team under *Signing & Capabilities*, plug in an iPhone, and run.
For the simulator slice: `LLAMA_BUILDS="ios-device ios-sim" ./scripts/build_llama.sh`.

## First launch

- The app opens on the gold keypad intro, then the PIN screen, exactly like Android.
- The first chat triggers a one-time 398 MB download of
  `Qwen2.5-0.5B-Instruct-abliterated.Q4_K_M.gguf` from Hugging Face
  (`mradermacher/Qwen2.5-0.5B-Instruct-abliterated-GGUF`). It is stored in
  Application Support and excluded from iCloud backup, so the `.ipa` stays ~15 MB.
- Inference then runs fully offline on the device (Metal via llama.cpp).
- Voice output needs the same ElevenLabs API key you use on Android. Voice input uses
  Apple's on-device/Apple-served speech recognition.

## Notes before shipping

- **Not compiled yet.** This project was generated in a Linux sandbox with no Xcode.
  The Swift and the XCFramework wiring follow llama.cpp `v0.9.0` and iOS 16.4 APIs, but
  expect the first CI run to surface at most small build fixes, not a redesign.
- **TestFlight build number** is `CURRENT_PROJECT_VERSION = 64` in `project.yml`;
  `CFBundleVersion` reads it. Nothing in the Android build 63 pipeline changes.
- **App Review.** The UI is still a WebView, so guideline 4.2 (minimum functionality)
  is a real risk; the native engine, speech and audio help, but a plain wrapper has been
  rejected before. If the app is public, the "zero refusal / abliterated" framing and
  unmoderated model output will also draw guideline 1.2 (user-generated content) scrutiny.
- **Fonts** load from Google Fonts; offline first run falls back to system serif/sans.
- **Downloads** from the chat export now route through `WKDownload` and a share sheet
  instead of silently failing inside the WebView.

## Media notes

- Only one avatar clip was uploaded (`Avatar_Video_720p.mp4`, 720×1280). It was a talking
  take with the portrait letterboxed on white and a HeyGen mark in the lower band. The
  white bands are now black so the frame blends into the dark UI, the mark is gone with
  them, and the audio track was dropped (`media/avatarTalk.mp4`).
- `media/avatarIdle.mp4` had no original in the upload, so it is rebuilt from a calm
  frame as a 6-second slow-zoom loop. If you still have the Android `avatarIdle.webm`,
  convert it to H.264/mp4 and replace that file — nothing else needs to change.
- Pin/posters (`pin.jpg`, `poster.jpg`, `intro.mp4`) came through as-is; the intro is
  pillarboxed by `.intro-video` because its 464:688 design frame is wider than the
  416×752 clip, which is invisible against the `#0c0a08` background.
- The PIN screen uses `object-fit: cover`, so on tall iPhones the invisible key targets
  sit a few points right of the printed keys. Key spacing is ~16% of the width, well
  beyond that offset, so taps still land on the intended digit.
