import AppKit
import AVFoundation
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
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
        throw TestFailure.assertion(message)
    }
}

@MainActor
private final class FakePermissionProvider: PermissionProviding {
    var cameraStatus: AVAuthorizationStatus = .notDetermined
    var grantedPermissions: Set<SetupPermission> = []
    var restartRequiredPermissions: Set<SetupPermission> = []
    var requestCounts: [SetupPermission: Int] = [:]
    var openedURLs: [URL] = []
    var openResults: [Bool] = []
    var probeCount = 0

    func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        probeCount += 1
        return cameraStatus
    }

    func isGranted(_ permission: SetupPermission) -> Bool {
        grantedPermissions.contains(permission)
    }

    func requiresApplicationRestart(for permission: SetupPermission) -> Bool {
        restartRequiredPermissions.contains(permission)
    }

    func requestCameraAccess() async {
        requestCounts[.camera, default: 0] += 1
    }

    func requestInputMonitoringAccess() {
        requestCounts[.inputMonitoring, default: 0] += 1
    }

    func requestAccessibilityAccess() {
        requestCounts[.accessibility, default: 0] += 1
    }

    func requestScreenRecordingAccess() {
        requestCounts[.screenRecording, default: 0] += 1
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return openResults.isEmpty ? true : openResults.removeFirst()
    }
}

@main
@MainActor
struct PermissionStateTests {
    static func main() async throws {
        try await testCameraAuthorizationMappings()
        try await testRefreshMapsBooleanPermissionsAndRestartRequirement()
        try await testRequestsForwardToProvider()
        try testSettingsAnchorFallsBackToGeneralPrivacyPage()
        try await testActivationAndVisibleStepPollingRefreshPermissions()
        print("Permission state tests passed")
    }

    private static func testCameraAuthorizationMappings() async throws {
        let cases: [(AVAuthorizationStatus, PermissionState)] = [
            (.notDetermined, .notDetermined),
            (.restricted, .denied),
            (.denied, .denied),
            (.authorized, .granted),
        ]

        for (authorizationStatus, expectedState) in cases {
            let provider = FakePermissionProvider()
            provider.cameraStatus = authorizationStatus
            let states = await PermissionCenter(provider: provider).refresh()
            try require(
                states[.camera] == expectedState,
                "\(authorizationStatus) mapped to \(String(describing: states[.camera]))"
            )
        }
    }

    private static func testRefreshMapsBooleanPermissionsAndRestartRequirement() async throws {
        let provider = FakePermissionProvider()
        provider.cameraStatus = .authorized
        provider.grantedPermissions = [.inputMonitoring, .accessibility]
        provider.restartRequiredPermissions = [.inputMonitoring]

        let states = await PermissionCenter(provider: provider).refresh()

        try require(states[.camera] == .granted, "authorized camera was not granted")
        try require(
            states[.inputMonitoring] == .restartRequired,
            "granted input monitoring restart requirement was not surfaced"
        )
        try require(states[.accessibility] == .granted, "trusted accessibility was not granted")
        try require(states[.screenRecording] == .denied, "missing screen recording was not denied")
    }

    private static func testRequestsForwardToProvider() async throws {
        let provider = FakePermissionProvider()
        let center = PermissionCenter(provider: provider)

        await center.requestCamera()
        center.requestInputMonitoring()
        center.requestAccessibility()
        center.requestScreenRecording()

        for permission in SetupPermission.allCases {
            try require(
                provider.requestCounts[permission] == 1,
                "\(permission.rawValue) request was not forwarded exactly once"
            )
        }
    }

    private static func testSettingsAnchorFallsBackToGeneralPrivacyPage() throws {
        let provider = FakePermissionProvider()
        provider.openResults = [false, true]
        let center = PermissionCenter(provider: provider)

        center.openSettings(for: .camera)

        try require(provider.openedURLs.count == 2, "settings fallback was not attempted")
        try require(
            provider.openedURLs.allSatisfy { $0.scheme == "x-apple.systempreferences" },
            "permission center attempted to open a non-Apple settings URL"
        )
        try require(
            provider.openedURLs[0].absoluteString.contains("Privacy_Camera"),
            "camera settings anchor was not used first"
        )
        try require(
            provider.openedURLs[1].absoluteString.hasSuffix("?Privacy"),
            "general Privacy & Security fallback was not used"
        )
    }

    private static func testActivationAndVisibleStepPollingRefreshPermissions() async throws {
        let provider = FakePermissionProvider()
        let notifications = NotificationCenter()
        let center = PermissionCenter(
            provider: provider,
            notificationCenter: notifications,
            pollingInterval: 0.01
        )

        center.setPermissionStepVisible(true)
        try await Task.sleep(nanoseconds: 35_000_000)
        center.setPermissionStepVisible(false)
        let afterPolling = provider.probeCount
        try require(afterPolling >= 2, "visible permission step did not poll")

        try await Task.sleep(nanoseconds: 20_000_000)
        try require(provider.probeCount == afterPolling, "hidden permission step kept polling")

        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        try require(
            provider.probeCount > afterPolling,
            "application activation did not refresh permissions"
        )
    }
}
