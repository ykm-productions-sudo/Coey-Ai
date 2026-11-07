import SwiftUI
import AVFoundation

@main
struct CoeyAiApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WebHostView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        return true
    }
}

struct WebHostView: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> WebHostController {
        WebHostController()
    }

    func updateUIViewController(_ uiViewController: WebHostController, context: Context) {}
}
