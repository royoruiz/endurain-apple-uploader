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
        XCTAssertEqual(store.totalCount, 0)
        XCTAssertTrue(store.pendingItems().isEmpty)
    }

    func testUpsertDoesNotDuplicateUUID() throws {
        let (store, _) = try makeStore()
        upsert(store, uuid: "same")
        upsert(store, uuid: "same")
        XCTAssertEqual(store.totalCount, 1)
    }

    func testUploadedDoesNotReturnToQueuedOnUpsert() throws {
        let (store, _) = try makeStore()
        upsert(store, uuid: "uploaded")
        store.markUploaded(uuid: "uploaded", serverURL: "https://example.com")
        upsert(store, uuid: "uploaded")
        XCTAssertTrue(store.pendingItems().isEmpty)
        XCTAssertEqual(store.uploadedItems().count, 1)
    }

    func testMarkUploadedPersistsUploadedAt() throws {
        let (store, directory) = try makeStore()
        upsert(store, uuid: "uploaded")
        store.markUploaded(uuid: "uploaded", serverURL: "https://example.com")

        let reloaded = try SyncQueueStore(baseDirectoryURL: directory)
        reloaded.load()
        XCTAssertNotNil(reloaded.item(for: "uploaded")?.uploadedAt)
        XCTAssertEqual(reloaded.item(for: "uploaded")?.status, .uploaded)
    }

    func testMarkFailedStoresLastError() throws {
        let (store, _) = try makeStore()
        upsert(store, uuid: "failed")
        store.markFailed(uuid: "failed", error: "boom")
        XCTAssertEqual(store.failedItems().first?.lastError, "boom")
    }

    func testPendingItemsDoesNotIncludeUploaded() throws {
        let (store, _) = try makeStore()
        upsert(store, uuid: "pending")
        upsert(store, uuid: "uploaded")
        store.markUploaded(uuid: "uploaded", serverURL: "https://example.com")
        XCTAssertEqual(store.pendingItems().map(\.workoutUUID), ["pending"])
    }

    func testLatestUploadedReturnsMostRecent() throws {
        let (store, _) = try makeStore()
        upsert(store, uuid: "first")
        store.markUploaded(uuid: "first", serverURL: "https://example.com")
        Thread.sleep(forTimeInterval: 0.01)
        upsert(store, uuid: "second")
        store.markUploaded(uuid: "second", serverURL: "https://example.com")
        XCTAssertEqual(store.latestUploaded()?.workoutUUID, "second")
    }

    func testSaveLoadConservesStates() throws {
        let (store, directory) = try makeStore()
        upsert(store, uuid: "queued")
        upsert(store, uuid: "failed")
        store.markFailed(uuid: "failed", error: "nope")

        let reloaded = try SyncQueueStore(baseDirectoryURL: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.item(for: "queued")?.status, .queued)
        XCTAssertEqual(reloaded.item(for: "failed")?.status, .failed)
    }

    func testFailedDoesNotBecomeQueuedWithoutRetry() throws {
        let (store, _) = try makeStore()
        upsert(store, uuid: "failed")
        store.markFailed(uuid: "failed", error: "nope")
        upsert(store, uuid: "failed")
        XCTAssertEqual(store.item(for: "failed")?.status, .failed)
    }

    private func upsert(_ store: SyncQueueStore, uuid: String) {
        store.upsertWorkout(
            uuid: uuid,
            startDate: Date(timeIntervalSince1970: 1),
            endDate: Date(timeIntervalSince1970: 61),
            activityTypeName: "Carrera",
            durationSeconds: 60,
            distanceMeters: 1000,
            serverURL: "https://example.com"
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
