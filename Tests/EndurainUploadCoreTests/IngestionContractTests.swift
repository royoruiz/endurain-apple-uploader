import Foundation
import XCTest
@testable import EndurainUploadCore

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class IngestionContractTests: XCTestCase {
    private let namespace = "test-account"
    private let uuid = "00000000-0000-4000-8000-000000000001"
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        StubURLProtocol.handler = nil
        // The parent runner removes its external scratch directory after verification.
    }

    private func queue() throws -> SyncQueueStore {
        let queue = try SyncQueueStore(baseDirectoryURL: scratch)
        queue.load()
        queue.upsertWorkout(namespaceID: namespace, normalizedServerURL: "https://example.invalid",
                            normalizedUserIdentifier: "test-user", uuid: uuid,
                            startDate: Date(timeIntervalSince1970: 0),
                            endDate: Date(timeIntervalSince1970: 3600),
                            activityTypeName: "Running", durationSeconds: 3600, distanceMeters: 12000)
        return queue
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient() -> EndurainClient {
        EndurainClient(serverURL: "https://example.invalid", apiKey: "test-key", session: session(),
                       receiptDirectoryURL: scratch.appendingPathComponent("receipts"))
    }

    private func job(_ status: String, id: String = "job-1", activities: String = "[]") -> Data {
        Data("""
        {"id":"\(id)","kind":"upload","status":"\(status)","activity_ids":\(activities),
         "created_at":"2020-01-01T00:00:00Z","updated_at":"2020-01-01T00:00:00Z"}
        """.utf8)
    }

    func testAcceptedUploadRetainsTCXAndRemainsUnconfirmed() throws {
        let queue = try queue()
        let file = queue.tcxQueueDirectoryURL.appendingPathComponent("test.tcx")
        try Data("<TrainingCenterDatabase/>".utf8).write(to: file)
        queue.markReadyToUpload(namespaceID: namespace, uuid: uuid, tcxFilePath: "test.tcx")
        queue.markUploading(namespaceID: namespace, uuid: uuid, taskIdentifier: 1)
        let service = BackgroundUploadService(queue: queue)

        service.handleCompletedTask(taskIdentifier: 1, error: nil, statusCode: 202, bodyData: job("pending"))

        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.status, .uploading)
        XCTAssertNil(queue.item(namespaceID: namespace, uuid: uuid)?.uploadedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testForegroundUsesV0202EndpointAndStableIdempotency() async throws {
        var requests: [URLRequest] = []
        StubURLProtocol.handler = { request in
            requests.append(request)
            return (200, Data("{}".utf8))
        }
        let client = makeClient()
        for _ in 0..<2 {
            _ = try await client.uploadActivityTCX(tcxData: Data("fixture".utf8), filename: "apple-health-\(uuid).tcx")
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/activities/upload")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-API-Key"), "test-key")
        let key = requests.first?.value(forHTTPHeaderField: "Idempotency-Key")
        XCTAssertNotNil(key)
        XCTAssertEqual(key, requests.last?.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testForegroundWaitsForAcceptedJobOutcome() async throws {
        var methods: [String] = []
        let accepted = job("pending")
        let completed = job("completed", activities: "[42]")
        StubURLProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { return (202, accepted) }
            XCTAssertEqual(request.url?.path, "/api/v1/activities/ingestion-jobs/job-1")
            return (200, completed)
        }
        let client = makeClient()
        let result = try await client.uploadActivityTCX(tcxData: Data("fixture".utf8), filename: "test.tcx")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    private func acceptedQueue(body: Data? = nil) throws -> (SyncQueueStore, URL) {
        let queue = try queue()
        let file = queue.tcxQueueDirectoryURL.appendingPathComponent("test.tcx")
        try Data("<TrainingCenterDatabase/>".utf8).write(to: file)
        queue.markReadyToUpload(namespaceID: namespace, uuid: uuid, tcxFilePath: "test.tcx")
        queue.markUploading(namespaceID: namespace, uuid: uuid, taskIdentifier: 1)
        BackgroundUploadService(queue: queue).handleCompletedTask(
            taskIdentifier: 1, error: nil, statusCode: 202, bodyData: body ?? job("pending"))
        return (queue, file)
    }

    func testAcceptedJobSurvivesRestartAndCannotBecomeAnotherPOST() throws {
        let (_, file) = try acceptedQueue()
        let reloaded = try SyncQueueStore(baseDirectoryURL: scratch)
        reloaded.load()
        reloaded.reconcileUploadingItems(activeTaskIdentifiers: [], staleAfter: -1)
        reloaded.requeue(namespaceID: namespace, uuid: uuid)
        XCTAssertEqual(reloaded.item(namespaceID: namespace, uuid: uuid)?.importJobID, "job-1")
        XCTAssertEqual(reloaded.item(namespaceID: namespace, uuid: uuid)?.status, .uploading)
        XCTAssertEqual(reloaded.pendingCount(namespaceID: namespace), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnresolvedDurableIntentCannotSilentlyReopenPOSTEligibility() throws {
        let queue = try queue()
        queue.markUploading(namespaceID: namespace, uuid: uuid, taskIdentifier: 1)
        try queue.ingestionReceipts.record(jobID: nil, scope: namespace, filename: "apple-health-\(uuid).tcx")
        let reloaded = try SyncQueueStore(baseDirectoryURL: scratch)
        reloaded.load()
        reloaded.reconcileUploadingItems(activeTaskIdentifiers: [], staleAfter: -1)
        reloaded.requeue(namespaceID: namespace, uuid: uuid)
        XCTAssertEqual(reloaded.pendingCount(namespaceID: namespace), 0)
        XCTAssertNotNil(reloaded.unconfirmedUploadError(namespaceID: namespace))
        XCTAssertNil(reloaded.item(namespaceID: namespace, uuid: uuid)?.uploadedAt)
    }

    func testRestartResumesGETUntilCompletionAndOnlyThenDeletesTCX() async throws {
        let (_, file) = try acceptedQueue()
        let reloaded = try SyncQueueStore(baseDirectoryURL: scratch)
        reloaded.load()
        var methods: [String] = []
        let processing = job("processing")
        let completed = job("completed", activities: "[42]")
        StubURLProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "test-key")
            return (200, methods.count == 1 ? processing : completed)
        }
        let monitor = ActivityImportMonitor(queue: reloaded, session: session())
        await monitor.refresh(namespaceID: namespace, serverURL: "https://example.invalid", apiKey: "test-key")
        XCTAssertEqual(reloaded.item(namespaceID: namespace, uuid: uuid)?.status, .uploading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await monitor.refresh(namespaceID: namespace, serverURL: "https://example.invalid", apiKey: "test-key")
        XCTAssertEqual(methods, ["GET", "GET"])
        XCTAssertEqual(reloaded.item(namespaceID: namespace, uuid: uuid)?.status, .uploaded)
        XCTAssertNotNil(reloaded.item(namespaceID: namespace, uuid: uuid)?.uploadedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let persisted = try SyncQueueStore(baseDirectoryURL: scratch)
        persisted.load()
        XCTAssertEqual(persisted.item(namespaceID: namespace, uuid: uuid)?.status, .uploaded)
    }

    func testFailedImportRetainsTCXAndJobInsteadOfReposting() async throws {
        let (queue, file) = try acceptedQueue()
        let failure = Data("""
        {"id":"job-1","kind":"upload","status":"failed","error_code":"invalid_file"}
        """.utf8)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, failure)
        }
        await ActivityImportMonitor(queue: queue, session: session()).refresh(
            namespaceID: namespace, serverURL: "https://example.invalid", apiKey: "test-key")
        queue.requeue(namespaceID: namespace, uuid: uuid)
        queue.requeueFailed(namespaceID: namespace, uuid: uuid)
        let item = queue.item(namespaceID: namespace, uuid: uuid)
        XCTAssertEqual(item?.status, .failed)
        XCTAssertEqual(item?.importJobID, "job-1")
        XCTAssertTrue(item?.lastError?.contains("invalid_file") == true)
        XCTAssertEqual(queue.pendingCount(namespaceID: namespace), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMalformedAcknowledgementDoesNotDeleteTCXOrClaimSuccess() throws {
        let (queue, file) = try acceptedQueue(body: Data("{}".utf8))
        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.status, .failed)
        XCTAssertNil(queue.item(namespaceID: namespace, uuid: uuid)?.uploadedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testJobGETFailureRetainsAcceptedIdentityAndFile() async throws {
        let (queue, file) = try acceptedQueue()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (503, Data())
        }
        await ActivityImportMonitor(queue: queue, session: session()).refresh(
            namespaceID: namespace, serverURL: "https://example.invalid", apiKey: "test-key")
        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.status, .uploading)
        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.importJobID, "job-1")
        XCTAssertNotNil(queue.item(namespaceID: namespace, uuid: uuid)?.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMismatchedJobCannotConfirmActivity() async throws {
        let (queue, file) = try acceptedQueue()
        let wrongJob = job("completed", id: "another-job", activities: "[42]")
        StubURLProtocol.handler = { _ in (200, wrongJob) }
        await ActivityImportMonitor(queue: queue, session: session()).refresh(
            namespaceID: namespace, serverURL: "https://example.invalid", apiKey: "test-key")
        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.status, .uploading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCompletionWithoutActivityDoesNotClaimSuccess() throws {
        let (queue, file) = try acceptedQueue(body: job("completed"))
        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testLostResponseRetryUsesSameKeyAcrossClientInstances() async throws {
        var keys: [String?] = []
        StubURLProtocol.handler = { request in
            keys.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
            if keys.count == 1 { throw URLError(.timedOut) }
            return (200, Data("{}".utf8))
        }
        let filename = "apple-health-\(uuid).tcx"
        do {
            _ = try await makeClient()
                .uploadActivityTCX(tcxData: Data("fixture".utf8), filename: filename)
            XCTFail("A lost response must not be reported as success")
        } catch {}
        _ = try await makeClient()
            .uploadActivityTCX(tcxData: Data("fixture".utf8), filename: filename)
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotNil(keys.first!)
        XCTAssertEqual(keys.first!, keys.last!)
    }

    func testExistingHTTP200StillConfirmsUpload() throws {
        let queue = try queue()
        queue.markUploading(namespaceID: namespace, uuid: uuid, taskIdentifier: 1)
        BackgroundUploadService(queue: queue).handleCompletedTask(
            taskIdentifier: 1, error: nil, statusCode: 200, bodyData: Data("{}".utf8))
        XCTAssertEqual(queue.item(namespaceID: namespace, uuid: uuid)?.status, .uploaded)
    }

    func testExistingErrorMappingStillHolds() {
        for status in [401, 403, 409, 429, 500, 405] {
            guard case .failure(let error) = UploadStatusMapper.map(statusCode: status, bodySummary: "") else {
                return XCTFail("HTTP \(status) must not succeed")
            }
            switch (status, error) {
            case (401, .unauthorized), (403, .unauthorized), (409, .duplicate),
                 (429, .rateLimited), (500, .serverError), (405, .uploadError): break
            default: XCTFail("Existing error classification changed for \(status)")
            }
        }
    }

    func testExistingUploadedAndSkippedHistoryLoadsWithoutJobFields() throws {
        let queue = try queue()
        queue.markSkipped(namespaceID: namespace, uuid: uuid, reason: "existing-history")
        let other = "00000000-0000-4000-8000-000000000002"
        queue.upsertWorkout(namespaceID: namespace, normalizedServerURL: "https://example.invalid",
                            normalizedUserIdentifier: "test-user", uuid: other,
                            startDate: Date(timeIntervalSince1970: 7200),
                            endDate: Date(timeIntervalSince1970: 10800),
                            activityTypeName: "Running", durationSeconds: 3600, distanceMeters: 12000)
        queue.markUploaded(namespaceID: namespace, uuid: other, serverURL: "https://example.invalid")
        let reloaded = try SyncQueueStore(baseDirectoryURL: scratch)
        reloaded.load()
        XCTAssertEqual(reloaded.item(namespaceID: namespace, uuid: uuid)?.status, .skipped)
        XCTAssertEqual(reloaded.item(namespaceID: namespace, uuid: other)?.status, .uploaded)
        XCTAssertNil(reloaded.item(namespaceID: namespace, uuid: other)?.importJobID)
        XCTAssertEqual(reloaded.pendingCount(namespaceID: namespace), 0)
    }
}
