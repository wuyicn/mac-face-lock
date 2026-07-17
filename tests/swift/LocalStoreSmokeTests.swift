import CoreFoundation
import Foundation

private enum SmokeTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw SmokeTestFailure.assertion(message)
    }
}

private func activityLine(
    index: Int,
    schemaVersionToken: String = "1",
    detail: String? = nil
) -> String {
    let detail = detail ?? "Detail \(index)"
    return """
    {"schema_version":\(schemaVersionToken),"id":"event-\(index)","timestamp":"2026-07-14T12:\(String(format: "%02d", index / 60)):\(String(format: "%02d", index % 60))+08:00","type":"decision","title":"Event \(index)","detail":"\(detail)","severity":"info","metadata":{"owner_hits":\(index),"frames_checked":\(index + 1)}}
    """
}

@main
struct LocalStoreSmokeTests {
    @MainActor
    static func main() throws {
        let fileManager = FileManager.default
        let projectURL = fileManager.temporaryDirectory
            .appendingPathComponent("mac-face-lock-store-\(UUID().uuidString)", isDirectory: true)
        let dataURL = projectURL.appendingPathComponent("data", isDirectory: true)

        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: projectURL) }

        let stateURL = dataURL.appendingPathComponent("state.json")
        let stateJSON = """
        {
          "status": "armed",
          "mode": "active",
          "armed": true,
          "action": "monitor",
          "heartbeat": "2026-07-14T12:00:00+08:00",
          "updated_at": "2026-07-14T12:00:01+08:00",
          "system_idle_seconds": 2.5,
          "last_decision": "owner",
          "last_reason": "owner_detected",
          "owner_hits": 4,
          "stranger_hits": 0,
          "no_face_hits": 1,
          "frames_checked": 5,
          "lock_reason": null,
          "lock_succeeded": false
        }
        """
        try Data(stateJSON.utf8).write(to: stateURL)

        let activityURL = dataURL.appendingPathComponent("activity.jsonl")
        var activityLines = (0..<205).map { activityLine(index: $0) }
        activityLines.insert("{malformed-json", at: 204)
        var activityData = Data((activityLines.joined(separator: "\n") + "\n").utf8)
        activityData.append(contentsOf: [0xFF, 0xFE, 0x0A])
        let crossChunkDetail = String(repeating: "x", count: 70_000)
        activityData.append(Data(activityLine(index: 205, detail: crossChunkDetail).utf8))
        activityData.append(0x0A)
        let unsupportedActivitySchemas = ["2", "1.0", "1e0", "true", "\"1\""]
        for (offset, schemaToken) in unsupportedActivitySchemas.enumerated() {
            activityData.append(
                Data(activityLine(index: 206 + offset, schemaVersionToken: schemaToken).utf8)
            )
            activityData.append(0x0A)
        }
        try activityData.write(to: activityURL)

        let store = LocalJSONStore(resourcesURL: projectURL, dataURL: dataURL)
        let state = store.readState()
        try require(state.status == "armed", "valid state status was not decoded")
        try require(state.armed, "valid state armed flag was not decoded")
        try require(state.systemIdleSeconds == 2.5, "snake_case state field was not decoded")
        try require(state.ownerHits == 4, "state hit counts were not decoded")
        try require(state.lockSucceeded == false, "lock success provenance was not decoded")

        let activities = store.readActivities()
        try require(activities.count == 200, "activity limit was not enforced after malformed-line skipping")
        try require(activities.first?.id == "event-205", "activities were not returned newest first")
        try require(activities.last?.id == "event-6", "activity limit retained the wrong oldest event")
        try require(activities.first?.metadata.framesChecked == 206, "activity metadata was not decoded")
        try require(activities.first?.detail == crossChunkDetail, "cross-chunk activity was not reconstructed")

        try fileManager.removeItem(at: stateURL)
        try require(store.readState() == .missing, "missing state did not return the sentinel")
        try Data("not-json".utf8).write(to: stateURL)
        try require(store.readState() == .missing, "malformed state did not return the sentinel")

        let missingControl = store.readControl()
        try require(missingControl.protectionEnabled, "missing control did not default to enabled")

        let writtenControl = try store.writeControl(enabled: false)
        let rereadControl = store.readControl()
        try require(rereadControl == writtenControl, "control did not round-trip exactly")
        try require(!rereadControl.protectionEnabled, "control enabled flag did not round-trip")

        let controlURL = dataURL.appendingPathComponent("control.json")
        let unsupportedControl = "{\"schema_version\":2,\"protection_enabled\":false,\"updated_at\":\"2026-07-14T12:00:00+08:00\"}"
        try Data(unsupportedControl.utf8).write(to: controlURL)
        try require(
            store.readControl().protectionEnabled,
            "unsupported control schema did not fall back to safe enabled"
        )
        for schemaToken in ["1.0", "1e0", "true", "\"1\""] {
            let invalidControl = "{\"schema_version\":\(schemaToken),\"protection_enabled\":false,\"updated_at\":\"2026-07-14T12:00:00+08:00\"}"
            try Data(invalidControl.utf8).write(to: controlURL)
            try require(
                store.readControl().protectionEnabled,
                "non-integer control schema token \(schemaToken) was accepted"
            )
        }
        _ = try store.writeControl(enabled: false)

        let preferencesURL = dataURL.appendingPathComponent("ui-preferences.json")
        try require(store.readPreferences() == UIPreferences(), "missing preferences did not return defaults")

        let preferences = UIPreferences(schemaVersion: 1, appearance: .dark, accent: .amethyst)
        try store.writePreferences(preferences)
        try require(store.readPreferences() == preferences, "preferences did not round-trip exactly")

        let unsupportedPreferencesJSON = "{\"schema_version\":2,\"appearance\":\"dark\",\"accent\":\"amethyst\"}"
        try Data(unsupportedPreferencesJSON.utf8).write(to: preferencesURL)
        try require(
            store.readPreferences() == UIPreferences(),
            "unsupported preferences schema did not return defaults"
        )
        for schemaToken in ["1.0", "1e0", "true", "\"1\""] {
            let invalidPreferences = "{\"schema_version\":\(schemaToken),\"appearance\":\"dark\",\"accent\":\"amethyst\"}"
            try Data(invalidPreferences.utf8).write(to: preferencesURL)
            try require(
                store.readPreferences() == UIPreferences(),
                "non-integer preferences schema token \(schemaToken) was accepted"
            )
        }
        var rejectedUnsupportedPreferencesWrite = false
        do {
            try store.writePreferences(
                UIPreferences(schemaVersion: 2, appearance: .dark, accent: .amethyst)
            )
        } catch {
            rejectedUnsupportedPreferencesWrite = true
        }
        try require(
            rejectedUnsupportedPreferencesWrite,
            "unsupported preferences schema was written"
        )

        try Data("{\"schema_version\":1,\"appearance\":\"unknown\",\"accent\":\"ocean_blue\"}".utf8)
            .write(to: preferencesURL)
        try require(store.readPreferences() == UIPreferences(), "unknown preferences did not return defaults")

        var overBudgetTail = Data((activityLine(index: 400) + "\n").utf8)
        overBudgetTail.append(Data(repeating: 0x78, count: 4 * 1_024 * 1_024 + 64 * 1_024))
        try overBudgetTail.write(to: activityURL)
        let boundedReadStartedAt = Date()
        let overBudgetActivities = store.readActivities(limit: 10)
        let boundedReadDuration = Date().timeIntervalSince(boundedReadStartedAt)
        try require(overBudgetActivities.isEmpty, "activity scan read past its byte budget")
        try require(boundedReadDuration < 2, "activity scan did not complete within its hard work bound")

        var oversizedRecordData = Data((activityLine(index: 500) + "\n").utf8)
        oversizedRecordData.append(Data(repeating: 0x78, count: 300 * 1_024))
        oversizedRecordData.append(0x0A)
        oversizedRecordData.append(Data((activityLine(index: 501) + "\n").utf8))
        try oversizedRecordData.write(to: activityURL)
        let oversizedRecordActivities = store.readActivities(limit: 10)
        try require(
            oversizedRecordActivities.map(\.id) == ["event-501", "event-500"],
            "oversized newline-free activity record hid neighboring valid events"
        )

        var overLineLimitData = Data((activityLine(index: 600) + "\n").utf8)
        overLineLimitData.append(Data(String(repeating: "{}\n", count: 10_001).utf8))
        try overLineLimitData.write(to: activityURL)
        try require(
            store.readActivities(limit: 10).isEmpty,
            "activity scan decoded past its line-count budget"
        )
        try activityData.write(to: activityURL)

        #if FACE_LOCK_STORE_SMOKE
        try Data(stateJSON.utf8).write(to: stateURL)
        let faceStore = FaceLockStore(localStore: store)
        faceStore.refresh()
        try require(faceStore.state.status == "armed", "face-lock store did not refresh state")
        try require(faceStore.activities.first?.id == "event-205", "face-lock store did not refresh activities")
        try require(!faceStore.protectionEnabled, "face-lock store did not refresh control")

        faceStore.setProtectionEnabled(true)
        try require(faceStore.protectionEnabled, "successful control write did not update published state")
        try require(store.readControl().protectionEnabled, "face-lock store did not persist control before updating")
        try require(faceStore.lastError == nil, "successful control write left an error")

        faceStore.startPolling()
        let pollingState = "{\"status\":\"polling\",\"armed\":false}"
        try Data(pollingState.utf8).write(to: stateURL)
        let trackingModeName = "FaceLockSmokeTrackingMode"
        let trackingMode = CFRunLoopMode(rawValue: trackingModeName as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), trackingMode)
        let eventTrackingMode = RunLoop.Mode(trackingModeName)
        let pollingDeadline = Date().addingTimeInterval(2.2)
        while Date() < pollingDeadline {
            _ = RunLoop.current.run(mode: eventTrackingMode, before: pollingDeadline)
        }
        try require(faceStore.state.status == "polling", "two-second poll did not refresh state")

        faceStore.stopPolling()
        let stoppedState = "{\"status\":\"stopped\",\"armed\":false}"
        try Data(stoppedState.utf8).write(to: stateURL)
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        try require(faceStore.state.status == "polling", "stopped poller continued refreshing")

        let blockedProjectURL = fileManager.temporaryDirectory
            .appendingPathComponent("mac-face-lock-blocked-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: blockedProjectURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: blockedProjectURL) }
        try Data("not-a-directory".utf8).write(to: blockedProjectURL.appendingPathComponent("data"))

        let blockedFaceStore = FaceLockStore(
            localStore: LocalJSONStore(
                resourcesURL: blockedProjectURL,
                dataURL: blockedProjectURL.appendingPathComponent("data", isDirectory: true)
            )
        )
        let previousProtectionState = blockedFaceStore.protectionEnabled
        blockedFaceStore.setProtectionEnabled(false)
        try require(
            blockedFaceStore.protectionEnabled == previousProtectionState,
            "failed control write changed published state"
        )
        try require(
            blockedFaceStore.lastError?.contains("保护") == true,
            "failed control write did not expose a user-readable Chinese error"
        )
        #endif

        print("Swift local store smoke tests passed")
    }
}
