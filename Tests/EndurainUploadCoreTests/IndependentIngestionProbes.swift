import Foundation
import CryptoKit
import XCTest
@testable import EndurainUploadCore

private final class IndependentWire: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.host == "offline.invalid", let handler = Self.respond else {
                throw URLError(.unsupportedURL)
            }
            let (code, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class IndependentIngestionProbes: XCTestCase {
    private let ns = "anonymous-account"
    private let uuid = "00000000-0000-4000-8000-000000000019"
    private let server = "https://offline.invalid"
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndependentIngestionProbes/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { IndependentWire.respond = nil }
    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [IndependentWire.self]
        return URLSession(configuration: c)
    }
    private func makeClient() -> EndurainClient {
        EndurainClient(serverURL: server, apiKey: "fixture", session: session(),
                       receiptDirectoryURL: root.appendingPathComponent("receipts"))
    }
    private func job(_ state: String, id: String = "accepted-19", ids: String = "[]",
                     kind: String = "upload", error: String = "null") -> Data {
        Data("{\"id\":\"\(id)\",\"kind\":\"\(kind)\",\"status\":\"\(state)\",\"activity_ids\":\(ids),\"error_code\":\(error)}".utf8)
    }
    private func queue() throws -> SyncQueueStore {
        let q = try SyncQueueStore(baseDirectoryURL: root)
        q.load()
        return q
    }
    private func add(_ q: SyncQueueStore, namespace: String? = nil, id: String? = nil) {
        q.upsertWorkout(namespaceID: namespace ?? ns, normalizedServerURL: server,
                        normalizedUserIdentifier: "anonymous", uuid: id ?? uuid,
                        startDate: Date(timeIntervalSince1970: 0),
                        endDate: Date(timeIntervalSince1970: 60), activityTypeName: "Running",
                        durationSeconds: 60, distanceMeters: nil)
    }
    private func ready(_ q: SyncQueueStore, task: Int = 19) throws -> URL {
        add(q)
        let f = q.tcxQueueDirectoryURL.appendingPathComponent("anonymous.tcx")
        try Data("<TrainingCenterDatabase/>".utf8).write(to: f)
        q.markReadyToUpload(namespaceID: ns, uuid: uuid, tcxFilePath: f.lastPathComponent)
        q.markUploading(namespaceID: ns, uuid: uuid, taskIdentifier: task)
        return f
    }
    private func digest(_ q: SyncQueueStore) throws -> String {
        let data = try Data(contentsOf: q.storageDirectoryURL.appendingPathComponent("sync-queue.json"))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // S3: same observable legacy HTTP handling on the named baseline and candidate.
    func testExistingBackgroundHTTPCompatibility() throws {
        let cases: [(Int, SyncStatus, String?, Bool)] = [
            (200, .uploaded, nil, false), (201, .uploaded, nil, false),
            (204, .uploaded, nil, false),
            (401, .failed, "API key is not authorized for activity upload or is invalid", true),
            (403, .failed, "API key is not authorized for activity upload or is invalid", true),
            (409, .skipped, "skippedExistingServerActivity", false),
            (429, .readyToUpload, "Endurain limitó las peticiones. Se reintentará automáticamente.", true),
            (503, .readyToUpload, "Endurain devolvió un error de servidor. Se reintentará automáticamente.", true),
            (405, .failed, "Endurain devolvió HTTP 405.", true)]
        for (code, status, message, retain) in cases {
            root = root.appendingPathComponent(String(code))
            let q = try queue(), file = try ready(q)
            BackgroundUploadService(queue: q).handleCompletedTask(
                taskIdentifier: 19, error: nil, statusCode: code, bodyData: Data())
            let item = try XCTUnwrap(q.item(namespaceID: ns, uuid: uuid))
            XCTAssertEqual(item.status, status); XCTAssertEqual(item.lastError, message)
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), retain)
            print("compat HTTP \(code): \(item.status.rawValue); error=\(item.lastError ?? "nil"); retain=\(retain)")
        }
    }

    // S3: foreground success and exact existing error strings remain unchanged.
    func testExistingForegroundHTTPCompatibility() async throws {
        for code in [200, 204, 401, 403, 409, 429, 503, 405] {
            IndependentWire.respond = { request in
                guard request.httpMethod == "POST" else { throw URLError(.unsupportedURL) }
                return (code, Data())
            }
            let client = makeClient()
            do {
                let result = try await client.uploadActivityTCX(tcxData: Data(), filename: "anonymous.tcx")
                XCTAssertTrue([200, 204].contains(code)); XCTAssertEqual(result.statusCode, code)
                XCTAssertEqual(result.responseBody, "")
            } catch {
                let messages = [401: "API key is not authorized for activity upload or is invalid.",
                    403: "API key is not authorized for activity upload or is invalid.",
                    409: "Duplicado: este entrenamiento ya existe en Endurain.",
                    429: "Demasiadas peticiones: Too many requests. Please try again later.",
                    503: "Error del servidor [503]: (sin body)", 405: "Error al subir [405]: (sin body)"]
                XCTAssertEqual(error.localizedDescription, messages[code])
            }
        }
    }

    // S1: once POST has returned an accepted identity, retry must resume that GET.
    func testForegroundAcceptedIdentitySurvivesClientRecreation() async throws {
        var methods: [String] = [], gets = 0
        let accepted = job("pending"), complete = job("completed", ids: "[19]")
        IndependentWire.respond = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { return (202, accepted) }
            guard request.httpMethod == "GET", request.url?.path == "/api/v1/activities/ingestion-jobs/accepted-19" else {
                throw URLError(.unsupportedURL)
            }
            gets += 1
            if gets == 1 { throw URLError(.timedOut) }
            return (200, complete)
        }
        let filename = "apple-health-\(uuid).tcx"
        do {
            _ = try await makeClient().uploadActivityTCX(tcxData: Data(), filename: filename)
            XCTFail("An accepted job with a failed GET must not report success")
        } catch {}
        let result = try await makeClient().uploadActivityTCX(tcxData: Data(), filename: filename)
        print("foreground resumed methods=\(methods); status=\(result.statusCode)")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(methods, ["POST", "GET", "GET"])
    }

    // S3: uploaded/skipped records written without ingestion fields remain byte-identical.
    func testLegacyHistoryRoundTripIsByteIdentical() throws {
        let q = try queue()
        add(q)
        add(q, namespace: "other-account")
        q.markUploaded(namespaceID: ns, uuid: uuid, serverURL: server)
        q.markSkipped(namespaceID: "other-account", uuid: uuid, reason: "existing-history")
        let before = try digest(q), loaded = try queue()
        loaded.resetInFlightItems()
        add(loaded); add(loaded, namespace: "other-account")
        XCTAssertTrue(loaded.save()); XCTAssertEqual(try digest(loaded), before)
        XCTAssertEqual(loaded.uploadedItems(namespaceID: ns).count, 1)
        XCTAssertEqual(loaded.skippedItems(namespaceID: "other-account").count, 1)
        XCTAssertEqual(loaded.pendingCount(namespaceID: ns), 0)
    }
}

extension IndependentIngestionProbes {
    private func accept(_ q: SyncQueueStore, body: Data? = nil) throws -> URL {
        let file = try ready(q)
        BackgroundUploadService(queue: q).handleCompletedTask(taskIdentifier: 19, error: nil,
            statusCode: 202, bodyData: body ?? job("pending"))
        return file
    }

    // S1,S3: accepted state, restart, late callback, GET matching, and namespace history.
    func testRestartGETOrderingAndNamespaceHistory() async throws {
        let q = try queue()
        add(q, namespace: "other-account")
        q.markSkipped(namespaceID: "other-account", uuid: uuid, reason: "existing-history")
        let file = try accept(q)
        XCTAssertNil(q.item(namespaceID: ns, uuid: uuid)?.uploadedAt)
        XCTAssertEqual(q.uploadedItems(namespaceID: ns).count, 0)
        XCTAssertEqual(q.uploadingCount(namespaceID: ns), 1)
        let loaded = try queue(), before = try digest(loaded)
        loaded.resetInFlightItems()
        loaded.reconcileUploadingItems(activeTaskIdentifiers: [], staleAfter: -1)
        loaded.requeue(namespaceID: ns, uuid: uuid)
        loaded.requeueFailed(namespaceID: ns, uuid: uuid)
        BackgroundUploadService(queue: loaded).handleCompletedTask(taskIdentifier: 19, error: nil,
            statusCode: 200, bodyData: Data())
        XCTAssertEqual(try digest(loaded), before)
        XCTAssertEqual(loaded.pendingCount(namespaceID: ns), 0)
        var paths: [String] = []
        let processing = job("processing"), completed = job("completed", ids: "[19]")
        IndependentWire.respond = { request in
            guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "X-API-Key") == "fixture" else {
                throw URLError(.unsupportedURL)
            }
            paths.append(request.url!.path)
            return (200, paths.count == 1 ? processing : completed)
        }
        let monitor = ActivityImportMonitor(queue: loaded, session: session())
        await monitor.refresh(namespaceID: ns, serverURL: server, apiKey: "fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(loaded.item(namespaceID: ns, uuid: uuid)?.status, .uploading)
        await monitor.refresh(namespaceID: ns, serverURL: server, apiKey: "fixture")
        XCTAssertEqual(paths, Array(repeating: "/api/v1/activities/ingestion-jobs/accepted-19", count: 2))
        XCTAssertEqual(try queue().item(namespaceID: ns, uuid: uuid)?.status, .uploaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(loaded.item(namespaceID: "other-account", uuid: uuid)?.status, .skipped)
        XCTAssertEqual(loaded.item(namespaceID: "other-account", uuid: uuid)?.lastError, "existing-history")
    }

    // S1,S3: failed polls must not reopen POST eligibility or accept another job.
    func testPollFailuresAndMismatchesKeepIdentityAndTCX() async throws {
        let q = try queue(), file = try accept(q)
        let wrong = job("completed", id: "unrelated", ids: "[19]")
        for code in [401, 404, 503, 200] {
            IndependentWire.respond = { request in
                guard request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
                return (code, wrong)
            }
            let monitor = ActivityImportMonitor(queue: q, session: session())
            await monitor.refresh(namespaceID: ns, serverURL: server, apiKey: "fixture")
            let before = try digest(q)
            await monitor.refresh(namespaceID: ns, serverURL: server, apiKey: "fixture")
            XCTAssertEqual(try digest(q), before)
            let item = try XCTUnwrap(try queue().item(namespaceID: ns, uuid: uuid))
            XCTAssertEqual(item.status, .uploading); XCTAssertEqual(item.importJobID, "accepted-19")
            XCTAssertEqual(item.lastError, "Unable to confirm import. The saved job will be checked again.")
            XCTAssertNil(item.uploadedAt); XCTAssertEqual(q.pendingCount(namespaceID: ns), 0)
            XCTAssertEqual(try Data(contentsOf: file), Data("<TrainingCenterDatabase/>".utf8))
        }
    }

    // S1,S3: malformed/terminal acknowledgements never confirm a local activity.
    func testAcknowledgementBoundariesAndTerminalRetention() throws {
        let invalid = [Data(), Data("{}".utf8), job("unknown"), job("pending", id: ""),
                       job("pending", id: ".."), job("pending", id: "a/b"),
                       job("pending", id: String(repeating: "a", count: 256)),
                       job("pending", kind: "download")]
        for data in invalid {
            let q = try queue(), before = q.totalCount
            XCTAssertThrowsError(try ActivityIngestionAPI.decodeJob(data))
            XCTAssertEqual(q.totalCount, before)
        }
        XCTAssertNoThrow(try ActivityIngestionAPI.decodeJob(job("pending", id: String(repeating: "a", count: 255))))
        for state in ["failed", "completed"] {
            root = root.appendingPathComponent(state)
            let q = try queue()
            let file = try accept(q, body: job(state, error: "\"invalid_file\""))
            let before = try digest(q)
            q.requeue(namespaceID: ns, uuid: uuid); q.requeueFailed(namespaceID: ns, uuid: uuid)
            XCTAssertEqual(try digest(q), before)
            let item = try XCTUnwrap(try queue().item(namespaceID: ns, uuid: uuid))
            XCTAssertEqual(item.status, .failed); XCTAssertEqual(item.importJobID, "accepted-19")
            XCTAssertEqual(item.lastError, state == "failed"
                ? "Endurain import failed (invalid_file). The TCX and job identifier have been retained."
                : "Import completed without an activity identifier. The TCX has been retained.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(q.pendingCount(namespaceID: ns), 0); XCTAssertEqual(q.failedCount(namespaceID: ns), 1)
        }
    }

    // S1: the normal background request builder and a foreground retry share one key.
    func testLostPOSTResponseKeepsStableCrossTransportKey() async throws {
        let q = try queue(), file = try ready(q)
        BackgroundUploadService(queue: q).handleCompletedTask(taskIdentifier: 19,
            error: URLError(.timedOut), statusCode: nil, bodyData: Data())
        XCTAssertEqual(q.item(namespaceID: ns, uuid: uuid)?.status, .readyToUpload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let filename = "apple-health-\(uuid).tcx"
        let expected = try ActivityIngestionAPI.uploadRequest(serverURL: server, apiKey: "fixture",
            filename: filename, boundary: "fixture").value(forHTTPHeaderField: "Idempotency-Key")
        var keys: [String?] = []
        IndependentWire.respond = { request in
            guard request.httpMethod == "POST", request.url?.path == "/api/v1/activities/upload" else {
                throw URLError(.unsupportedURL)
            }
            keys.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("name=\"file\"; filename=\"\(filename)\""))
            if keys.count == 1 { throw URLError(.timedOut) }
            return (200, Data())
        }
        do {
            _ = try await makeClient().uploadActivityTCX(tcxData: Data(), filename: filename)
            XCTFail("A lost POST response must fail")
        } catch {}
        _ = try await makeClient().uploadActivityTCX(tcxData: Data(), filename: filename)
        XCTAssertNotNil(expected); XCTAssertEqual(keys, [expected, expected])
        XCTAssertEqual(ActivityIngestionAPI.idempotencyKey(filename: filename.uppercased()), expected)
    }

    // S1: failure to save a 202 must not silently lose its accepted job on restart.
    func testAcceptedJobIsDurableWhenQueueSaveFails() throws {
        let q = try queue(), file = try ready(q), before = try digest(q)
        // A deterministic local I/O failure, without chmod or permission changes.
        try FileManager.default.createDirectory(at: q.storageDirectoryURL.appendingPathComponent("sync-queue.tmp.json"),
                                                withIntermediateDirectories: false)
        BackgroundUploadService(queue: q).handleCompletedTask(taskIdentifier: 19, error: nil,
            statusCode: 202, bodyData: job("pending"))
        XCTAssertEqual(try digest(q), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let loaded = try queue()
        loaded.reconcileUploadingItems(activeTaskIdentifiers: [], staleAfter: -1)
        print("save failure: memory job=\(q.item(namespaceID: ns, uuid: uuid)?.importJobID ?? "nil"); disk job=\(loaded.item(namespaceID: ns, uuid: uuid)?.importJobID ?? "nil"); pending=\(loaded.pendingCount(namespaceID: ns))")
        XCTAssertEqual(loaded.item(namespaceID: ns, uuid: uuid)?.importJobID, "accepted-19")
        XCTAssertEqual(loaded.pendingCount(namespaceID: ns), 0)
    }
}
