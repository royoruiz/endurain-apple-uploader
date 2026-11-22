// swift-tools-version: 5.9
import PackageDescription

// Hostless tests: no app entry point, HealthKit, Keychain, or external dependencies.
let package = Package(
    name: "EndurainUploadCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "EndurainUploadCore",
            path: "EndurainAppleUploader/EndurainAppleUploader",
            exclude: [
                "APIKeyMasker.swift", "AppDelegate.swift", "AppResetService.swift",
                "ContentView.swift", "EndurainAppleUploader.entitlements",
                "EndurainAppleUploaderApp.swift", "HealthKitBackgroundObserver.swift",
                "HealthKitService.swift", "KeychainService.swift", "PendingWorkout.swift",
                "SettingsStore.swift", "SettingsView.swift", "StatusView.swift",
                "SyncEngine.swift", "TCXGenerator.swift", "UploadStore.swift",
                "WorkoutDetail.swift", "WorkoutSummary.swift",
            ],
            sources: [
                "ActivityIngestion.swift", "AppLog.swift", "BackgroundUploadService.swift", "EndurainClient.swift",
                "MultipartFormBuilder.swift", "ServerURLNormalizer.swift",
                "SyncQueueStore.swift", "UploadStatusMapper.swift",
            ]
        ),
        .testTarget(
            name: "EndurainUploadCoreTests",
            dependencies: ["EndurainUploadCore"],
            path: "Tests/EndurainUploadCoreTests"
        ),
    ]
)
