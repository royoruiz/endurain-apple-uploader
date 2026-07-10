//
//  APIKeyMasker.swift
//  EndurainAppleUploader
//

import Foundation

enum APIKeyMasker {
    static func mask(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 1)) }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }
}
