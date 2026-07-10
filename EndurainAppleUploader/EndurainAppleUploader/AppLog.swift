//
//  AppLog.swift
//  EndurainAppleUploader
//

import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "es.overtus.EndurainUploaderiOS"

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let upload = Logger(subsystem: subsystem, category: "upload")
    static let healthKit = Logger(subsystem: subsystem, category: "healthkit")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
