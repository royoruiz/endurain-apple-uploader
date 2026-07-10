//
//  MultipartFormBuilder.swift
//  EndurainAppleUploader
//

import Foundation

enum MultipartFormBuilder {
    static let fileFieldName = "file"
    static let tcxContentType = "application/vnd.garmin.tcx+xml"

    static func body(tcxData: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        let crlf = "\r\n"

        body.appendUTF8("--\(boundary)\(crlf)")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\(crlf)")
        body.appendUTF8("Content-Type: \(tcxContentType)\(crlf)")
        body.appendUTF8(crlf)
        body.append(tcxData)
        body.appendUTF8(crlf)
        body.appendUTF8("--\(boundary)--\(crlf)")

        return body
    }

    static func writeBodyFile(
        tcxFileURL: URL,
        filename: String,
        boundary: String,
        outputURL: URL
    ) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Type: \(tcxContentType)\r\n\r\n".utf8))
        try handle.write(contentsOf: Data(contentsOf: tcxFileURL))
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
