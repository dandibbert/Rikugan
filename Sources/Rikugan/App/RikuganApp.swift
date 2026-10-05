import SwiftUI
import AVFoundation
import UserNotifications

@main
struct RikuganApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            BrowserWindowScene()
                .environmentObject(services)
                .onOpenURL { url in services.handleIncoming(url) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background audio / Picture in Picture for web media (spec §28).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            SelfTestRunner.configureFromLaunchArguments()
            AppServices.shared.start()
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) {
            MainActor.assumeIsolated { AppServices.shared.handleIncoming(url) }
        }
        completionHandler()
    }
}

/// One browser window (scene). iPad supports multiple windows, Split View and Stage Manager.
struct BrowserWindowScene: View {
    @EnvironmentObject private var services: AppServices
    @SceneStorage("rikugan.windowID") private var windowID = ""

    var body: some View {
        Group {
            if let id = UUID(uuidString: windowID) {
                BrowserWindowHost(windowID: id)
            } else {
                Color(.systemBackground).onAppear { windowID = UUID().uuidString }
            }
        }
    }
}

struct BrowserWindowHost: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var manager: TabManager
    @Environment(\.scenePhase) private var scenePhase

    init(windowID: UUID) {
        _manager = StateObject(wrappedValue: TabManager(windowID: windowID, profile: AppServices.shared.profile))
    }

    var body: some View {
        BrowserView()
            .tint(Theme.color)
            .onAppear { Theme.applyToWindows() }
            .environmentObject(manager)
            .environmentObject(services.profile)
            .environmentObject(services.profile.extensions)
            .environmentObject(services.profile.userscripts)
            .environmentObject(services.downloads)
            .environmentObject(services.adBlock)
            .environmentObject(services.fonts)
            .environmentObject(services.autofill)
            .environmentObject(ToastCenter.shared)
            .environmentObject(UserscriptInstallCoordinator.shared)
            .environmentObject(ExtensionInstaller.shared)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    TabRegistry.shared.focus(manager)
                    BackgroundHostContainer.shared.flush()
                    services.consumeSharedPendingItems()
                case .background, .inactive:
                    // Keep the current page's thumbnail for the tab switcher after a relaunch.
                    manager.activeTab?.captureThumbnail()
                    manager.save()
                    // The app may be suspended right after this: write pending files now.
                    PersistenceQueue.shared.flush()
                @unknown default: break
                }
            }
            .onDisappear { manager.save() }
    }
}
