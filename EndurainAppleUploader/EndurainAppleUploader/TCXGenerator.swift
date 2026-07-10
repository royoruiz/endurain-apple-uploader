//
//  TCXGenerator.swift
//  EndurainAppleUploader
//
//  Created by Nicolas Royo Ruiz on 09/07/2026.
//

import Foundation
import HealthKit
import CoreLocation

struct TCXGenerator {

    // MARK: - Public entry point

    static func generate(from detail: WorkoutDetail) -> String {
        let sport = xmlEscaped(sportString(for: detail.activityType))
        let startISO = iso8601(detail.startDate)

        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<TrainingCenterDatabase"
        xml += " xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\""
        xml += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
        xml += " xsi:schemaLocation=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
        xml += " http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd\">\n"
        xml += "  <Activities>\n"
        xml += "    <Activity Sport=\"\(sport)\">\n"
        xml += "      <Id>\(startISO)</Id>\n"
        xml += "      <Lap StartTime=\"\(startISO)\">\n"
        xml += "        <TotalTimeSeconds>\(Int(detail.durationSeconds))</TotalTimeSeconds>\n"

        if let dist = detail.totalDistanceMeters {
            xml += "        <DistanceMeters>\(String(format: "%.2f", dist))</DistanceMeters>\n"
        }
        if let kcal = detail.activeEnergyKcal {
            xml += "        <Calories>\(Int(kcal))</Calories>\n"
        }

        xml += "        <Intensity>Active</Intensity>\n"
        xml += "        <TriggerMethod>Manual</TriggerMethod>\n"
        xml += "        <Track>\n"
        xml += buildTrack(from: detail)
        xml += "        </Track>\n"
        xml += "      </Lap>\n"
        xml += "    </Activity>\n"
        xml += "  </Activities>\n"
        xml += "</TrainingCenterDatabase>\n"

        return xml
    }

    // MARK: - Track building

    private static func buildTrack(from detail: WorkoutDetail) -> String {
        guard !detail.routePoints.isEmpty else { return "" }

        var track = ""
        var accumulatedDistance: Double = 0.0
        var prevLocation: CLLocation? = nil

        for point in detail.routePoints {
            let currentLocation = CLLocation(
                latitude: point.latitude,
                longitude: point.longitude
            )

            if let prev = prevLocation {
                accumulatedDistance += currentLocation.distance(from: prev)
            }
            prevLocation = currentLocation

            track += "          <Trackpoint>\n"
            track += "            <Time>\(iso8601(point.timestamp))</Time>\n"
            track += "            <Position>\n"
            track += "              <LatitudeDegrees>\(point.latitude)</LatitudeDegrees>\n"
            track += "              <LongitudeDegrees>\(point.longitude)</LongitudeDegrees>\n"
            track += "            </Position>\n"

            if let alt = point.altitude {
                track += "            <AltitudeMeters>\(String(format: "%.2f", alt))</AltitudeMeters>\n"
            }

            track += "            <DistanceMeters>\(String(format: "%.2f", accumulatedDistance))</DistanceMeters>\n"

            if let bpm = closestHR(to: point, in: detail.heartRateSamples) {
                track += "            <HeartRateBpm>\n"
                track += "              <Value>\(bpm)</Value>\n"
                track += "            </HeartRateBpm>\n"
            }

            track += "          </Trackpoint>\n"
        }

        return track
    }

    // MARK: - Heart rate matching

    /// Devuelve el BPM de la muestra más cercana al punto dado, dentro de ±windowSeconds.
    private static func closestHR(
        to point: RoutePoint,
        in samples: [HeartRateSample],
        windowSeconds: Double = 10.0
    ) -> Int? {
        guard !samples.isEmpty else { return nil }

        var bestDiff = Double.greatestFiniteMagnitude
        var bestBPM: Double? = nil

        for sample in samples {
            let diff = abs(sample.timestamp.timeIntervalSince(point.timestamp))
            if diff < bestDiff {
                bestDiff = diff
                bestBPM = sample.bpm
            }
            // Los samples están ordenados por tiempo; si ya pasamos la ventana, paramos.
            if sample.timestamp.timeIntervalSince(point.timestamp) > windowSeconds {
                break
            }
        }

        guard let bpm = bestBPM, bestDiff <= windowSeconds else { return nil }
        return Int(bpm.rounded())
    }

    // MARK: - Sport mapping

    private static func sportString(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running, .walking, .hiking, .trackAndField,
             .wheelchairRunPace, .wheelchairWalkPace:
            return "Running"
        case .cycling, .handCycling:
            return "Biking"
        default:
            return "Other"
        }
    }

    // MARK: - ISO 8601 formatter

    private static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
