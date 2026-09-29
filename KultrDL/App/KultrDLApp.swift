import AVFoundation
import BackgroundTasks
import KultrDLCore
import SwiftUI
import UIKit

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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background tasks have to be registered before launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Downloads.backgroundTaskId, using: DispatchQueue.main) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { AppGraph.shared.downloads.run(task) }
        }
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
}
