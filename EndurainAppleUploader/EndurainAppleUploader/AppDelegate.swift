//
//  AppDelegate.swift
//  EndurainAppleUploader
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploadService.sessionIdentifier else {
            completionHandler()
            return
        }

        Task { @MainActor in
            BackgroundURLSessionCompletionStore.setCompletionHandler(completionHandler)
        }
    }
}
