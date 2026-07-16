import CoreFoundation
import Foundation

private enum LocalJSONStoreError: Error {
    case unsupportedSchemaVersion
}

final class LocalJSONStore {
    private static let activityScanByteLimit: UInt64 = 4 * 1_024 * 1_024
    private static let activityRecordByteLimit = 256 * 1_024
    private static let activityLineLimit = 10_000

    let projectURL: URL
    let dataURL: URL

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(projectURL: URL, dataURL: URL) {
        self.projectURL = projectURL
        self.dataURL = dataURL

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func readState() -> FaceLockState {
        read(FaceLockState.self, from: dataURL.appendingPathComponent("state.json")) ?? .missing
    }

    func readActivities(limit: Int = 200) -> [ActivityEvent] {
        guard limit > 0,
              let file = try? FileHandle(
                  forReadingFrom: dataURL.appendingPathComponent("activity.jsonl")
              ),
              let endOffset = try? file.seekToEnd() else {
            return []
        }
        defer { try? file.close() }

        let bytesToRead = min(endOffset, Self.activityScanByteLimit)
        let readOffset = endOffset - bytesToRead
        guard (try? file.seek(toOffset: readOffset)) != nil,
              let scannedData = try? file.read(upToCount: Int(bytesToRead)),
              !scannedData.isEmpty else {
            return []
        }

        let contentStart: Data.Index
        let firstFragmentIsComplete: Bool
        if readOffset == 0 {
            contentStart = scannedData.startIndex
            firstFragmentIsComplete = true
        } else {
            firstFragmentIsComplete = scannedData.first == 0x0A
            contentStart = scannedData.index(after: scannedData.startIndex)
        }

        var events: [ActivityEvent] = []
        var linesScanned = 0
        var lineEnd = scannedData.endIndex

        if lineEnd > contentStart,
           scannedData[scannedData.index(before: lineEnd)] == 0x0A {
            lineEnd = scannedData.index(before: lineEnd)
        }

        while lineEnd > contentStart,
              events.count < limit,
              linesScanned < Self.activityLineLimit {
            var lineStart = lineEnd
            var delimiterIndex: Data.Index?

            while lineStart > contentStart {
                let previousIndex = scannedData.index(before: lineStart)
                if scannedData[previousIndex] == 0x0A {
                    delimiterIndex = previousIndex
                    break
                }
                lineStart = previousIndex
            }

            if let delimiterIndex {
                lineStart = scannedData.index(after: delimiterIndex)
            } else {
                lineStart = contentStart
            }

            linesScanned += 1
            let lineIsComplete = delimiterIndex != nil || firstFragmentIsComplete
            let lineSize = scannedData.distance(from: lineStart, to: lineEnd)

            if lineIsComplete, lineSize > 0, lineSize <= Self.activityRecordByteLimit {
                let recordData = Data(scannedData[lineStart..<lineEnd])
                if hasSupportedSchemaVersion(in: recordData),
                   let event = try? decoder.decode(ActivityEvent.self, from: recordData),
                   event.schemaVersion == 1 {
                    events.append(event)
                }
            }

            guard let delimiterIndex else {
                break
            }
            lineEnd = delimiterIndex
        }

        return events
    }

    func readControl() -> ControlFile {
        guard let control = readVersioned(
            ControlFile.self,
            from: dataURL.appendingPathComponent("control.json")
        ), control.schemaVersion == 1 else {
            return ControlFile(protectionEnabled: true, updatedAt: "")
        }
        return control
    }

    func writeControl(enabled: Bool) throws -> ControlFile {
        let control = ControlFile(
            protectionEnabled: enabled,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try write(control, to: dataURL.appendingPathComponent("control.json"))
        return control
    }

    func readPreferences() -> UIPreferences {
        guard let preferences = readVersioned(
            UIPreferences.self,
            from: dataURL.appendingPathComponent("ui-preferences.json")
        ), preferences.schemaVersion == 1 else {
            return UIPreferences()
        }
        return preferences
    }

    func writePreferences(_ preferences: UIPreferences) throws {
        guard preferences.schemaVersion == 1 else {
            throw LocalJSONStoreError.unsupportedSchemaVersion
        }
        try write(preferences, to: dataURL.appendingPathComponent("ui-preferences.json"))
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }

    private func readVersioned<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url),
              hasSupportedSchemaVersion(in: data) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }

    private func hasSupportedSchemaVersion(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let number = dictionary["schema_version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return false
        }
        return number.compare(NSNumber(value: 1)) == .orderedSame
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
