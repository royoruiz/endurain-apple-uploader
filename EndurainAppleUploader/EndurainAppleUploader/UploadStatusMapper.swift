//
//  UploadStatusMapper.swift
//  EndurainAppleUploader
//

import Foundation

enum UploadStatusMapper {
    static func map(statusCode: Int, bodySummary: String) -> Result<UploadResult, EndurainClientError> {
        switch statusCode {
        case 200...299:
            return .success(UploadResult(statusCode: statusCode, responseBody: bodySummary))
        case 401, 403:
            return .failure(.unauthorized)
        case 409:
            return .failure(.duplicate(bodySummary))
        case 429:
            return .failure(.rateLimited(bodySummary))
        case 500...599:
            return .failure(.serverError(statusCode, bodySummary))
        default:
            return .failure(.uploadError(statusCode, bodySummary))
        }
    }
}
