import AVFoundation
import BackgroundTasks
import KultrDLCore
import SwiftUI
import UIKit
import UserNotifications

@main
struct KultrDLApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in AppGraph.shared.actions.open(url) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background tasks have to be registered before launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Downloads.backgroundTaskId, using: DispatchQueue.main) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { AppGraph.shared.downloads.run(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Recommender.backgroundTaskId, using: DispatchQueue.main) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { AppGraph.shared.recommender.run(task) }
        }
        UNUserNotificationCenter.current().delegate = self
        _ = AppGraph.shared
        application.beginReceivingRemoteControlEvents()
        #if DEBUG
        ScreenshotDriver.start()
        #endif
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        MainActor.assumeIsolated {
            let graph = AppGraph.shared
            graph.library.saveNow()
            graph.downloads.scheduleProcessing()
            graph.recommender.schedule()
            let listening = graph.listening
            Task { await listening.saveNow() }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        MainActor.assumeIsolated {
            let graph = AppGraph.shared
            graph.library.checkFiles()
            graph.downloads.start()
            graph.updateEngineIfDue()
        }
    }

    // A new-release alert was tapped: show Home, where they are.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            let graph = AppGraph.shared
            if graph.ui.playerOpen { graph.actions.closePlayer() }
            graph.ui.tab = .home
            graph.ui.setPath([], for: .home)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
