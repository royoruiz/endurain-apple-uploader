//
//  EndurainAppleUploaderTests.swift
//  EndurainAppleUploaderTests
//

import XCTest
import HealthKit
@testable import EndurainAppleUploader

final class ServerURLNormalizerTests: XCTestCase {
    func testAddsHTTPSWhenSchemeIsMissing() throws {
        XCTAssertEqual(
            try ServerURLNormalizer.normalize("endurain.home.royoruiz.es"),
            "https://endurain.home.royoruiz.es"
        )
    }

    func testTrimsWhitespaceAndTrailingSlash() throws {
        XCTAssertEqual(
            try ServerURLNormalizer.normalize(" https://endurain.home.royoruiz.es/ "),
            "https://endurain.home.royoruiz.es"
        )
    }

    func testKeepsExplicitHTTPURL() throws {
        XCTAssertEqual(
            try ServerURLNormalizer.normalize("http://192.168.1.50:8080/"),
            "http://192.168.1.50:8080"
        )
    }

    func testEmptyURLFails() {
        XCTAssertThrowsError(try ServerURLNormalizer.normalize(""))
    }

    func testUnsupportedSchemeFails() {
        XCTAssertThrowsError(try ServerURLNormalizer.normalize("ftp://endurain.home.royoruiz.es"))
    }

    func testLowercasesHostname() throws {
        XCTAssertEqual(
            try ServerURLNormalizer.normalize(" HTTPS://Endurain.Home.RoyoRuiz.Es:8443/ "),
            "https://endurain.home.royoruiz.es:8443"
        )
    }
}

final class EndurainConfigurationIdentityTests: XCTestCase {
    func testSameServerAndUserWithDifferentTokenWouldUseSameNamespace() throws {
        let first = try EndurainConfigurationIdentity(serverURL: "https://server-a.example.com", userIdentifier: "nicolas")
        let second = try EndurainConfigurationIdentity(serverURL: "https://server-a.example.com", userIdentifier: "NICOLAS")

        XCTAssertEqual(first.namespaceID, second.namespaceID)
    }

    func testDifferentUserUsesDifferentNamespace() throws {
        let first = try EndurainConfigurationIdentity(serverURL: "https://server-a.example.com", userIdentifier: "nicolas")
        let second = try EndurainConfigurationIdentity(serverURL: "https://server-a.example.com", userIdentifier: "otheruser")

        XCTAssertNotEqual(first.namespaceID, second.namespaceID)
    }

    func testDifferentServerUsesDifferentNamespace() throws {
        let first = try EndurainConfigurationIdentity(serverURL: "https://server-a.example.com", userIdentifier: "nicolas")
        let second = try EndurainConfigurationIdentity(serverURL: "https://server-b.example.com", userIdentifier: "nicolas")

        XCTAssertNotEqual(first.namespaceID, second.namespaceID)
    }

    func testURLCaseAndTrailingSlashNormalizeToSameNamespace() throws {
        let first = try EndurainConfigurationIdentity(serverURL: "HTTPS://SERVER-A.EXAMPLE.COM/", userIdentifier: " Nicolas ")
        let second = try EndurainConfigurationIdentity(serverURL: "https://server-a.example.com", userIdentifier: "nicolas")

        XCTAssertEqual(first.namespaceID, second.namespaceID)
    }
}

final class APIKeyMaskerTests: XCTestCase {
    func testMasksMiddleOfLongAPIKey() {
        XCTAssertEqual(APIKeyMasker.mask("abcd1234wxyz"), "abcd••••wxyz")
    }

    func testShortStringDoesNotCrash() {
        XCTAssertFalse(APIKeyMasker.mask("abc").isEmpty)
    }
}

final class SyncQueueStoreTests: XCTestCase {
    private func makeStore() throws -> (SyncQueueStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SyncQueueStore(baseDirectoryURL: directory)
        store.load()
        return (store, directory)
    }

    func testLoadEmptyCreatesEmptyQueue() throws {
        let (store, _) = try makeStore()
        let namespace = try identity().namespaceID
        XCTAssertEqual(store.totalCount, 0)
        XCTAssertTrue(store.pendingItems(namespaceID: namespace).isEmpty)
    }

    func testTokenRotationKeepsSameWorkoutUploaded() throws {
        let (store, _) = try makeStore()
        let token1 = try identity(server: "https://server-a.example.com", user: "nicolas")
        let token2 = try identity(server: "https://server-a.example.com", user: "NICOLAS")

        upsert(store, namespace: token1, uuid: "workout")
        store.markUploaded(namespaceID: token1.namespaceID, uuid: "workout", serverURL: token1.normalizedServerURL)

        XCTAssertEqual(token1.namespaceID, token2.namespaceID)
        XCTAssertTrue(store.isUploaded(namespaceID: token2.namespaceID, uuid: "workout"))
        upsert(store, namespace: token2, uuid: "workout")
        XCTAssertTrue(store.pendingItems(namespaceID: token2.namespaceID).isEmpty)
    }

    func testServerChangeDoesNotReuseUploadedState() throws {
        let (store, _) = try makeStore()
        let serverA = try identity(server: "https://server-a.example.com", user: "nicolas")
        let serverB = try identity(server: "https://server-b.example.com", user: "nicolas")

        upsert(store, namespace: serverA, uuid: "workout")
        store.markUploaded(namespaceID: serverA.namespaceID, uuid: "workout", serverURL: serverA.normalizedServerURL)

        XCTAssertFalse(store.isUploaded(namespaceID: serverB.namespaceID, uuid: "workout"))
        upsert(store, namespace: serverB, uuid: "workout")
        XCTAssertEqual(store.item(namespaceID: serverB.namespaceID, uuid: "workout")?.status, .queued)
    }

    func testUserChangeDoesNotReuseUploadedState() throws {
        let (store, _) = try makeStore()
        let nicolas = try identity(server: "https://server-a.example.com", user: "nicolas")
        let other = try identity(server: "https://server-a.example.com", user: "otheruser")

        upsert(store, namespace: nicolas, uuid: "workout")
        store.markUploaded(namespaceID: nicolas.namespaceID, uuid: "workout", serverURL: nicolas.normalizedServerURL)

        XCTAssertFalse(store.isUploaded(namespaceID: other.namespaceID, uuid: "workout"))
        upsert(store, namespace: other, uuid: "workout")
        XCTAssertEqual(store.item(namespaceID: other.namespaceID, uuid: "workout")?.status, .queued)
    }

    func testUploadedDoesNotReturnToQueuedOnUpsertInSameNamespace() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "uploaded")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "uploaded", serverURL: namespace.normalizedServerURL)
        upsert(store, namespace: namespace, uuid: "uploaded")
        XCTAssertTrue(store.pendingItems(namespaceID: namespace.namespaceID).isEmpty)
        XCTAssertEqual(store.uploadedItems(namespaceID: namespace.namespaceID).count, 1)
    }

    func testMarkUploadedPersistsUploadedAt() throws {
        let (store, directory) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "uploaded")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "uploaded", serverURL: namespace.normalizedServerURL)

        let reloaded = try SyncQueueStore(baseDirectoryURL: directory)
        reloaded.load()
        XCTAssertNotNil(reloaded.item(namespaceID: namespace.namespaceID, uuid: "uploaded")?.uploadedAt)
        XCTAssertEqual(reloaded.item(namespaceID: namespace.namespaceID, uuid: "uploaded")?.status, .uploaded)
    }

    func testMarkFailedStoresLastError() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "failed")
        store.markFailed(namespaceID: namespace.namespaceID, uuid: "failed", error: "boom")
        XCTAssertEqual(store.failedItems(namespaceID: namespace.namespaceID).first?.lastError, "boom")
    }

    func testPendingItemsDoesNotIncludeUploaded() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "pending")
        upsert(store, namespace: namespace, uuid: "uploaded")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "uploaded", serverURL: namespace.normalizedServerURL)
        XCTAssertEqual(store.pendingItems(namespaceID: namespace.namespaceID).map(\.workoutUUID), ["pending"])
    }

    func testLatestUploadedReturnsMostRecentInNamespace() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "first")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "first", serverURL: namespace.normalizedServerURL)
        Thread.sleep(forTimeInterval: 0.01)
        upsert(store, namespace: namespace, uuid: "second")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "second", serverURL: namespace.normalizedServerURL)
        XCTAssertEqual(store.latestUploaded(namespaceID: namespace.namespaceID)?.workoutUUID, "second")
    }

    func testSaveLoadConservesStates() throws {
        let (store, directory) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "queued")
        upsert(store, namespace: namespace, uuid: "failed")
        store.markFailed(namespaceID: namespace.namespaceID, uuid: "failed", error: "nope")

        let reloaded = try SyncQueueStore(baseDirectoryURL: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.item(namespaceID: namespace.namespaceID, uuid: "queued")?.status, .queued)
        XCTAssertEqual(reloaded.item(namespaceID: namespace.namespaceID, uuid: "failed")?.status, .failed)
    }

    func testFailedDoesNotBecomeQueuedWithoutRetry() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "failed")
        store.markFailed(namespaceID: namespace.namespaceID, uuid: "failed", error: "nope")
        upsert(store, namespace: namespace, uuid: "failed")
        XCTAssertEqual(store.item(namespaceID: namespace.namespaceID, uuid: "failed")?.status, .failed)
    }

    func testDifferentUUIDWithSimilarWorkoutIsDetectedAsDuplicate() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "original")

        let duplicate = store.likelyDuplicate(
            namespaceID: namespace.namespaceID,
            uuid: "different-uuid",
            startDate: Date(timeIntervalSince1970: 61),
            activityTypeName: "Carrera",
            durationSeconds: 62,
            distanceMeters: 1010
        )

        XCTAssertEqual(duplicate?.workoutUUID, "original")
    }

    func testDifferentDayIsNotDuplicate() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "original")

        let duplicate = store.likelyDuplicate(
            namespaceID: namespace.namespaceID,
            uuid: "next-day",
            startDate: Date(timeIntervalSince1970: 86_400),
            activityTypeName: "Carrera",
            durationSeconds: 60,
            distanceMeters: 1000
        )

        XCTAssertNil(duplicate)
    }

    func testSameStartButDifferentDistanceIsNotDuplicate() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "original")

        let duplicate = store.likelyDuplicate(
            namespaceID: namespace.namespaceID,
            uuid: "different-distance",
            startDate: Date(timeIntervalSince1970: 1),
            activityTypeName: "Carrera",
            durationSeconds: 60,
            distanceMeters: 3000
        )

        XCTAssertNil(duplicate)
    }

    func testUploadedDuplicateCanBeFoundByItem() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "uploaded")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "uploaded", serverURL: namespace.normalizedServerURL)
        upsert(store, namespace: namespace, uuid: "candidate", startDate: Date(timeIntervalSince1970: 30), durationSeconds: 61, distanceMeters: 1005)

        let duplicate = store.likelyDuplicate(
            of: try XCTUnwrap(store.item(namespaceID: namespace.namespaceID, uuid: "candidate")),
            restrictedTo: [.uploaded]
        )

        XCTAssertEqual(duplicate?.workoutUUID, "uploaded")
    }

    func testDeleteHistoryForNamespaceAllowsFreshStart() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "uploaded")
        store.markUploaded(namespaceID: namespace.namespaceID, uuid: "uploaded", serverURL: namespace.normalizedServerURL)

        try store.deleteHistory(namespaceID: namespace.namespaceID)

        XCTAssertNil(store.latestUploaded(namespaceID: namespace.namespaceID))
        XCTAssertTrue(store.pendingItems(namespaceID: namespace.namespaceID).isEmpty)

        upsert(store, namespace: namespace, uuid: "uploaded")
        XCTAssertEqual(store.item(namespaceID: namespace.namespaceID, uuid: "uploaded")?.status, .queued)
    }

    func testDeleteHistoryForNamespaceDoesNotDeleteOtherNamespace() throws {
        let (store, _) = try makeStore()
        let namespaceA = try identity(server: "https://server-a.example.com", user: "nicolas")
        let namespaceB = try identity(server: "https://server-b.example.com", user: "nicolas")
        upsert(store, namespace: namespaceA, uuid: "workout")
        upsert(store, namespace: namespaceB, uuid: "workout")
        store.markUploaded(namespaceID: namespaceA.namespaceID, uuid: "workout", serverURL: namespaceA.normalizedServerURL)
        store.markUploaded(namespaceID: namespaceB.namespaceID, uuid: "workout", serverURL: namespaceB.normalizedServerURL)

        try store.deleteHistory(namespaceID: namespaceA.namespaceID)

        XCTAssertFalse(store.isUploaded(namespaceID: namespaceA.namespaceID, uuid: "workout"))
        XCTAssertTrue(store.isUploaded(namespaceID: namespaceB.namespaceID, uuid: "workout"))
    }

    func testDeleteHistoryForNamespaceRemovesAssociatedFiles() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "workout")
        let namespaceTCXDirectory = store.tcxQueueDirectoryURL.appendingPathComponent(namespace.namespaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: namespaceTCXDirectory, withIntermediateDirectories: true)
        let tcxFileURL = namespaceTCXDirectory.appendingPathComponent("workout.tcx")
        try Data("tcx".utf8).write(to: tcxFileURL)

        let multipartDirectory = store.storageDirectoryURL
            .appendingPathComponent(SyncQueueStore.multipartSubdir, isDirectory: true)
            .appendingPathComponent(namespace.namespaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: multipartDirectory, withIntermediateDirectories: true)
        let multipartFileURL = multipartDirectory.appendingPathComponent("workout.multipart")
        try Data("multipart".utf8).write(to: multipartFileURL)
        store.markReadyToUpload(namespaceID: namespace.namespaceID, uuid: "workout", tcxFilePath: namespace.namespaceID + "/workout.tcx")
        store.markUploading(namespaceID: namespace.namespaceID, uuid: "workout", taskIdentifier: 44, multipartFilePath: SyncQueueStore.multipartSubdir + "/" + namespace.namespaceID + "/workout.multipart")

        try store.deleteHistory(namespaceID: namespace.namespaceID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tcxFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: multipartFileURL.path))
    }

    @MainActor
    func testStaleBackgroundCallbackAfterClearDoesNotMarkUploaded() throws {
        let (store, _) = try makeStore()
        let namespace = try identity()
        upsert(store, namespace: namespace, uuid: "stale")
        store.markUploading(namespaceID: namespace.namespaceID, uuid: "stale", taskIdentifier: 123, multipartFilePath: nil)
        let backgroundUploads = BackgroundUploadService(queue: store)

        try store.deleteHistory(namespaceID: namespace.namespaceID)
        backgroundUploads.handleCompletedTask(
            taskIdentifier: 123,
            error: nil,
            statusCode: 201,
            bodyData: Data("ok".utf8)
        )

        XCTAssertEqual(store.totalCount, 0)
        XCTAssertNil(store.latestUploaded(namespaceID: namespace.namespaceID))
    }

    func testLegacyRecordsDoNotBlockNamespacedUploads() throws {
        let (store, _) = try makeStore()
        let legacy = SyncQueueItem(
            workoutUUID: "workout",
            startDate: Date(timeIntervalSince1970: 1),
            endDate: Date(timeIntervalSince1970: 2),
            activityTypeName: "Carrera",
            distanceMeters: 1,
            durationSeconds: 1,
            status: .uploaded,
            tcxFilePath: nil,
            retryCount: 0,
            lastError: nil,
            uploadedAt: Date(timeIntervalSince1970: 3),
            serverURL: "https://legacy.example.com",
            fileHash: nil,
            backgroundTaskIdentifier: nil,
            multipartFilePath: nil,
            uploadStartedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder.iso8601QueueEncoder.encode([legacy])
        let queueFile = store.storageDirectoryURL.appendingPathComponent("sync-queue.json")
        try data.write(to: queueFile)
        store.load()
        let namespace = try identity()

        XCTAssertEqual(store.legacyItems().count, 1)
        XCTAssertFalse(store.isUploaded(namespaceID: namespace.namespaceID, uuid: "workout"))
        upsert(store, namespace: namespace, uuid: "workout")
        XCTAssertEqual(store.item(namespaceID: namespace.namespaceID, uuid: "workout")?.status, .queued)
    }

    private func identity(
        server: String = "https://example.com",
        user: String = "nicolas"
    ) throws -> EndurainConfigurationIdentity {
        try EndurainConfigurationIdentity(serverURL: server, userIdentifier: user)
    }

    private func upsert(
        _ store: SyncQueueStore,
        namespace: EndurainConfigurationIdentity,
        uuid: String,
        startDate: Date = Date(timeIntervalSince1970: 1),
        durationSeconds: Double = 60,
        distanceMeters: Double? = 1000
    ) {
        store.upsertWorkout(
            namespaceID: namespace.namespaceID,
            normalizedServerURL: namespace.normalizedServerURL,
            normalizedUserIdentifier: namespace.normalizedUserIdentifier,
            uuid: uuid,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(durationSeconds),
            activityTypeName: "Carrera",
            durationSeconds: durationSeconds,
            distanceMeters: distanceMeters
        )
    }
}

private extension JSONEncoder {
    static var iso8601QueueEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

@MainActor
final class AppResetServiceTests: XCTestCase {
    func testDefaultDeleteConfigurationPreservesUploadHistory() async throws {
        let context = try makeContext()
        let identity = try context.settings.currentIdentity()
        upsert(context.queue, namespace: identity, uuid: "workout")
        context.queue.markUploaded(namespaceID: identity.namespaceID, uuid: "workout", serverURL: identity.normalizedServerURL)

        try await context.reset.deleteConfiguration(deleteUploadHistory: false)

        XCTAssertFalse(context.settings.isConfigured)
        XCTAssertEqual(context.settings.serverURL, "")
        XCTAssertEqual(context.settings.userIdentifier, "")
        XCTAssertNil(try context.keychain.read())
        XCTAssertTrue(context.queue.isUploaded(namespaceID: identity.namespaceID, uuid: "workout"))

        try context.settings.save(serverURL: "https://server-a.example.com", userIdentifier: "nicolas", apiKey: "secret-b")
        XCTAssertTrue(context.queue.isUploaded(namespaceID: identity.namespaceID, uuid: "workout"))
        upsert(context.queue, namespace: identity, uuid: "workout")
        XCTAssertTrue(context.queue.pendingItems(namespaceID: identity.namespaceID).isEmpty)
    }

    func testDeleteConfigurationWithHistoryResetAllowsFreshStart() async throws {
        let context = try makeContext()
        let identity = try context.settings.currentIdentity()
        upsert(context.queue, namespace: identity, uuid: "workout")
        context.queue.markUploaded(namespaceID: identity.namespaceID, uuid: "workout", serverURL: identity.normalizedServerURL)

        try await context.reset.deleteConfiguration(deleteUploadHistory: true)

        XCTAssertFalse(context.queue.isUploaded(namespaceID: identity.namespaceID, uuid: "workout"))
        try context.settings.save(serverURL: "https://server-a.example.com", userIdentifier: "nicolas", apiKey: "secret-b")
        upsert(context.queue, namespace: identity, uuid: "workout")
        XCTAssertEqual(context.queue.item(namespaceID: identity.namespaceID, uuid: "workout")?.status, .queued)
    }

    func testHistoryResetRemovesOnlyCurrentNamespace() async throws {
        let context = try makeContext()
        let namespaceA = try context.settings.currentIdentity()
        let namespaceB = try EndurainConfigurationIdentity(serverURL: "https://server-b.example.com", userIdentifier: "nicolas")
        upsert(context.queue, namespace: namespaceA, uuid: "workout")
        upsert(context.queue, namespace: namespaceB, uuid: "workout")
        context.queue.markUploaded(namespaceID: namespaceA.namespaceID, uuid: "workout", serverURL: namespaceA.normalizedServerURL)
        context.queue.markUploaded(namespaceID: namespaceB.namespaceID, uuid: "workout", serverURL: namespaceB.normalizedServerURL)

        try await context.reset.deleteConfiguration(deleteUploadHistory: true)

        XCTAssertFalse(context.queue.isUploaded(namespaceID: namespaceA.namespaceID, uuid: "workout"))
        XCTAssertTrue(context.queue.isUploaded(namespaceID: namespaceB.namespaceID, uuid: "workout"))
    }

    func testDuplicateUploadResponseMarksSkippedExistingServerActivity() async throws {
        let context = try makeContext()
        let identity = try context.settings.currentIdentity()
        upsert(context.queue, namespace: identity, uuid: "workout")
        context.queue.markUploading(namespaceID: identity.namespaceID, uuid: "workout", taskIdentifier: 456, multipartFilePath: nil)

        context.backgroundUploads.handleCompletedTask(
            taskIdentifier: 456,
            error: nil,
            statusCode: 409,
            bodyData: Data("duplicate".utf8)
        )

        XCTAssertEqual(context.queue.item(namespaceID: identity.namespaceID, uuid: "workout")?.status, .skipped)
        XCTAssertEqual(context.queue.item(namespaceID: identity.namespaceID, uuid: "workout")?.lastError, "skippedExistingServerActivity")
        XCTAssertNil(context.queue.latestUploaded(namespaceID: identity.namespaceID))
    }

    private struct Context {
        let settings: SettingsStore
        let keychain: KeychainService
        let queue: SyncQueueStore
        let backgroundUploads: BackgroundUploadService
        let reset: AppResetService
    }

    private func makeContext() throws -> Context {
        let identifier = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppResetServiceTests.\(identifier)"))
        let keychain = KeychainService(service: "AppResetServiceTests.\(identifier)", account: "apiKey")
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        try settings.save(serverURL: "https://server-a.example.com", userIdentifier: "nicolas", apiKey: "secret-a")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try SyncQueueStore(baseDirectoryURL: directory)
        queue.load()
        let backgroundUploads = BackgroundUploadService(queue: queue)
        let reset = AppResetService(
            settings: settings,
            queue: queue,
            uploadStore: UploadStore(defaults: defaults),
            backgroundUploadService: backgroundUploads
        )
        return Context(settings: settings, keychain: keychain, queue: queue, backgroundUploads: backgroundUploads, reset: reset)
    }

    private func upsert(_ queue: SyncQueueStore, namespace: EndurainConfigurationIdentity, uuid: String) {
        queue.upsertWorkout(
            namespaceID: namespace.namespaceID,
            normalizedServerURL: namespace.normalizedServerURL,
            normalizedUserIdentifier: namespace.normalizedUserIdentifier,
            uuid: uuid,
            startDate: Date(timeIntervalSince1970: 1),
            endDate: Date(timeIntervalSince1970: 2),
            activityTypeName: "Carrera",
            durationSeconds: 1,
            distanceMeters: 1
        )
    }
}

final class TCXGeneratorTests: XCTestCase {
    func testGeneratesExpectedTCXWithRouteAndHeartRate() {
        let xml = TCXGenerator.generate(from: sampleWorkoutDetail(route: true, heartRate: true))

        XCTAssertFalse(xml.isEmpty)
        XCTAssertTrue(xml.contains("TrainingCenterDatabase"))
        XCTAssertTrue(xml.contains("<Activity"))
        XCTAssertTrue(xml.contains("<Lap"))
        XCTAssertTrue(xml.contains("<TotalTimeSeconds>60</TotalTimeSeconds>"))
        XCTAssertTrue(xml.contains("<DistanceMeters>1000.00</DistanceMeters>"))
        XCTAssertTrue(xml.contains("<Trackpoint>"))
        XCTAssertTrue(xml.contains("<LatitudeDegrees>"))
        XCTAssertTrue(xml.contains("<LongitudeDegrees>"))
        XCTAssertTrue(xml.contains("<HeartRateBpm>"))
    }

    func testEscapesXMLStrings() {
        XCTAssertEqual(
            TCXGenerator.xmlEscaped("A&B <C> \"D\" 'E'"),
            "A&amp;B &lt;C&gt; &quot;D&quot; &apos;E&apos;"
        )
    }

    func testGeneratesValidTCXWithoutRoute() {
        let xml = TCXGenerator.generate(from: sampleWorkoutDetail(route: false, heartRate: false))
        XCTAssertTrue(xml.contains("TrainingCenterDatabase"))
        XCTAssertTrue(xml.contains("<Track>"))
        XCTAssertFalse(xml.contains("<Trackpoint>"))
    }

    private func sampleWorkoutDetail(route: Bool, heartRate: Bool) -> WorkoutDetail {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let routePoints = route ? [
            RoutePoint(timestamp: start, latitude: 38.1, longitude: -0.5, altitude: 10, horizontalAccuracy: 5),
            RoutePoint(timestamp: start.addingTimeInterval(5), latitude: 38.2, longitude: -0.6, altitude: 12, horizontalAccuracy: 5)
        ] : []
        let heartRateSamples = heartRate ? [HeartRateSample(timestamp: start, bpm: 140)] : []

        return WorkoutDetail(
            id: UUID(),
            activityType: .running,
            activityTypeName: "Carrera",
            startDate: start,
            endDate: start.addingTimeInterval(60),
            durationSeconds: 60,
            totalDistanceMeters: 1000,
            activeEnergyKcal: 50,
            routePoints: routePoints,
            heartRateSamples: heartRateSamples
        )
    }
}

final class MultipartFormBuilderTests: XCTestCase {
    func testBuildsExpectedMultipartBodyWithoutAPIKey() throws {
        let uuid = "ABC-123"
        let tcx = Data("<tcx>hello</tcx>".utf8)
        let boundary = "Boundary-Test"
        let filename = "apple-health-\(uuid).tcx"
        let body = MultipartFormBuilder.body(tcxData: tcx, filename: filename, boundary: boundary)
        let string = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(string.contains(boundary))
        XCTAssertTrue(string.contains("name=\"file\""))
        XCTAssertTrue(string.contains("filename=\"apple-health-ABC-123.tcx\""))
        XCTAssertTrue(string.contains("Content-Type: application/vnd.garmin.tcx+xml"))
        XCTAssertTrue(string.contains("<tcx>hello</tcx>"))
        XCTAssertFalse(string.contains("secret-api-key"))
    }
}

final class UploadStatusMapperTests: XCTestCase {
    func testTwoHundredIsSuccess() throws {
        let result = UploadStatusMapper.map(statusCode: 201, bodySummary: "ok")
        XCTAssertNoThrow(try result.get())
    }

    func testUnauthorizedStatusMapsToUnauthorized() {
        assertFailure(UploadStatusMapper.map(statusCode: 401, bodySummary: ""), expected: .unauthorized)
        assertFailure(UploadStatusMapper.map(statusCode: 403, bodySummary: ""), expected: .unauthorized)
    }

    func testConflictMapsToDuplicate() {
        assertFailure(UploadStatusMapper.map(statusCode: 409, bodySummary: "dup"), expected: .duplicate("dup"))
    }

    func testServerErrorMapsToServerError() {
        assertFailure(UploadStatusMapper.map(statusCode: 500, bodySummary: "server"), expected: .serverError(500, "server"))
    }

    private func assertFailure(
        _ result: Result<UploadResult, EndurainClientError>,
        expected: EndurainClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected failure", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }
}

final class EndurainActivityLookupTests: XCTestCase {
    func testExtractActivitiesFindsNestedActivityObjects() throws {
        let object: [String: Any] = [
            "items": [
                [
                    "id": 1,
                    "start_time": "2026-07-10T10:00:00Z",
                    "total_timer_time": 3600,
                    "distance": 10_000
                ]
            ]
        ]

        let activities = EndurainClient.extractActivities(from: object)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.durationSeconds, 3600)
        XCTAssertEqual(activities.first?.distanceMeters, 10_000)
    }

    func testEquivalentServerActivityMatchesLocalWorkout() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let item = SyncQueueItem(
            workoutUUID: "workout",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            activityTypeName: "Carrera",
            distanceMeters: 10_000,
            durationSeconds: 3600,
            status: .queued,
            tcxFilePath: nil,
            retryCount: 0,
            lastError: nil,
            uploadedAt: nil,
            serverURL: "https://example.com",
            fileHash: nil,
            backgroundTaskIdentifier: nil,
            multipartFilePath: nil,
            uploadStartedAt: nil,
            createdAt: start
        )
        let activity = EndurainServerActivity(
            startDate: start.addingTimeInterval(45),
            durationSeconds: 3610,
            distanceMeters: 10_050
        )

        XCTAssertTrue(EndurainClient.isEquivalent(activity, to: item))
    }

    func testDifferentServerActivityDoesNotMatchLocalWorkout() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let item = SyncQueueItem(
            workoutUUID: "workout",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            activityTypeName: "Carrera",
            distanceMeters: 10_000,
            durationSeconds: 3600,
            status: .queued,
            tcxFilePath: nil,
            retryCount: 0,
            lastError: nil,
            uploadedAt: nil,
            serverURL: "https://example.com",
            fileHash: nil,
            backgroundTaskIdentifier: nil,
            multipartFilePath: nil,
            uploadStartedAt: nil,
            createdAt: start
        )
        let activity = EndurainServerActivity(
            startDate: start.addingTimeInterval(30 * 60),
            durationSeconds: 3600,
            distanceMeters: 10_000
        )

        XCTAssertFalse(EndurainClient.isEquivalent(activity, to: item))
    }
}
