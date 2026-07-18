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

private func makeStore() throws -> (root: URL, store: LocalJSONStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-face-lock-setup-\(UUID().uuidString)", isDirectory: true)
    let dataURL = root.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
    return (
        root,
        LocalJSONStore(resourcesURL: root, dataURL: dataURL)
    )
}

@main
struct SetupStateTests {
    static func main() throws {
        try testReadinessRequiresEveryRequiredGate()
        try testScreenRecordingTracksScreenshotEvidencePolicy()
        try testMissingAndUnknownOnboardingRecordsAreIncomplete()
        try testOnboardingRoundTripPersistsProgressWithoutPermissionClaims()
        try testReleaseMissingOnboardingPersistsDisabledControl()
        try testSourceMissingOnboardingPreservesEnabledFallback()
        try testCompletedReleaseOnboardingPreservesControl()
        try testCompletedRoutingKeepsRecoveryAvailableWhenLiveHealthIsLost()
        try testLegacyCleanupAttentionOverridesCompletedRouting()
        print("Setup state tests passed")
    }

    private static func testReadinessRequiresEveryRequiredGate() throws {
        let grantedPermissions: [SetupPermission: PermissionState] = [
            .camera: .granted,
            .inputMonitoring: .granted,
            .accessibility: .granted,
        ]
        let ready = SetupReadiness.evaluate(
            permissions: grantedPermissions,
            ownerProfileValid: true,
            diagnosisPassed: true,
            ownerTestPassed: true,
            serviceHealthy: true
        )
        try require(ready.canEnableProtection, "all required gates should enable protection")

        for permission in [
            SetupPermission.camera,
            .inputMonitoring,
            .accessibility,
        ] {
            var permissions = grantedPermissions
            permissions[permission] = .denied
            let blocked = SetupReadiness.evaluate(
                permissions: permissions,
                ownerProfileValid: true,
                diagnosisPassed: true,
                ownerTestPassed: true,
                serviceHealthy: true
            )
            try require(
                !blocked.canEnableProtection,
                "denied \(permission.rawValue) must block protection"
            )
        }

        let booleanGates: [(SetupCheck, SetupReadiness)] = [
            (
                .ownerProfile,
                SetupReadiness.evaluate(
                    permissions: grantedPermissions,
                    ownerProfileValid: false,
                    diagnosisPassed: true,
                    ownerTestPassed: true,
                    serviceHealthy: true
                )
            ),
            (
                .diagnosis,
                SetupReadiness.evaluate(
                    permissions: grantedPermissions,
                    ownerProfileValid: true,
                    diagnosisPassed: false,
                    ownerTestPassed: true,
                    serviceHealthy: true
                )
            ),
            (
                .ownerTest,
                SetupReadiness.evaluate(
                    permissions: grantedPermissions,
                    ownerProfileValid: true,
                    diagnosisPassed: true,
                    ownerTestPassed: false,
                    serviceHealthy: true
                )
            ),
            (
                .serviceHealth,
                SetupReadiness.evaluate(
                    permissions: grantedPermissions,
                    ownerProfileValid: true,
                    diagnosisPassed: true,
                    ownerTestPassed: true,
                    serviceHealthy: false
                )
            ),
        ]
        for (check, readiness) in booleanGates {
            try require(
                !readiness.canEnableProtection,
                "failed \(check.rawValue) must block protection"
            )
            try require(
                readiness.checks[check] == false,
                "failed \(check.rawValue) was not exposed in readiness checks"
            )
        }
    }

    private static func testScreenRecordingTracksScreenshotEvidencePolicy() throws {
        let permissions: [SetupPermission: PermissionState] = [
            .camera: .granted,
            .inputMonitoring: .granted,
            .accessibility: .granted,
            .screenRecording: .denied,
        ]
        let evidenceDisabled = SetupReadiness.evaluate(
            permissions: permissions,
            ownerProfileValid: true,
            diagnosisPassed: true,
            ownerTestPassed: true,
            serviceHealthy: true
        )
        try require(
            evidenceDisabled.canEnableProtection,
            "screen recording must be optional while screenshot evidence is disabled"
        )
        try require(
            !evidenceDisabled.requiredChecks.contains(.screenRecordingPermission),
            "disabled screenshot evidence incorrectly required screen recording"
        )

        let evidenceEnabled = SetupReadiness.evaluate(
            permissions: permissions,
            ownerProfileValid: true,
            diagnosisPassed: true,
            ownerTestPassed: true,
            serviceHealthy: true,
            screenshotEvidenceEnabled: true
        )
        try require(
            !evidenceEnabled.canEnableProtection,
            "enabled screenshot evidence must require screen recording"
        )
        try require(
            evidenceEnabled.requiredChecks.contains(.screenRecordingPermission),
            "enabled screenshot evidence did not require screen recording"
        )
    }

    private static func testMissingAndUnknownOnboardingRecordsAreIncomplete() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let missing = fixture.store.readOnboarding()
        try require(!missing.isComplete, "missing onboarding record was marked complete")
        try require(missing.currentStep == .preparation, "missing onboarding did not start at preparation")
        try require(missing.completedSteps.isEmpty, "missing onboarding had completed steps")

        let unknownSchema = """
        {
          "schema_version": 2,
          "current_step": "completion",
          "completed_steps": ["preparation", "permissions", "enrollment", "safety_test", "completion"],
          "completed_at": "2026-07-17T12:00:00+08:00",
          "app_version": "9.9.9"
        }
        """
        try Data(unknownSchema.utf8).write(
            to: fixture.store.dataURL.appendingPathComponent("onboarding.json")
        )
        let rejected = fixture.store.readOnboarding()
        try require(!rejected.isComplete, "unknown onboarding schema was marked complete")
        try require(rejected == .incomplete, "unknown onboarding schema did not return defaults")

        let syntheticUnknown = OnboardingRecord(
            schemaVersion: 2,
            currentStep: .completion,
            completedSteps: SetupStep.allCases,
            completedAt: "2026-07-17T12:00:00+08:00",
            appVersion: "9.9.9"
        )
        try require(
            !syntheticUnknown.isComplete,
            "unknown in-memory onboarding schema was marked complete"
        )
    }

    private static func testOnboardingRoundTripPersistsProgressWithoutPermissionClaims() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let setupStore = try SetupStore(
            localStore: fixture.store,
            mode: .source
        )
        let record = OnboardingRecord(
            currentStep: .safetyTest,
            completedSteps: [.preparation, .permissions, .enrollment],
            completedAt: nil,
            appVersion: "0.1.0-beta"
        )
        try setupStore.save(record)

        try require(setupStore.record == record, "setup store did not retain the saved record")
        try require(fixture.store.readOnboarding() == record, "onboarding record did not round-trip")

        let onboardingURL = fixture.store.dataURL.appendingPathComponent("onboarding.json")
        let persisted = try Data(contentsOf: onboardingURL)
        let json = try JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        try require(json?["schema_version"] as? Int == 1, "onboarding schema version was not persisted")
        try require(json?["current_step"] as? String == "safety_test", "current step was not persisted")
        try require(
            json?["completed_steps"] as? [String]
                == ["preparation", "permissions", "enrollment"],
            "completed steps were not persisted"
        )
        try require(json?["completed_at"] == nil, "nil completion timestamp was persisted")
        try require(json?["app_version"] as? String == "0.1.0-beta", "app version was not persisted")

        let persistedText = String(decoding: persisted, as: UTF8.self)
        try require(
            json?["permissions"] == nil && !persistedText.contains("granted"),
            "onboarding persistence stored a synthetic permission grant"
        )
    }

    private static func testCompletedRoutingKeepsRecoveryAvailableWhenLiveHealthIsLost()
        throws {
        try require(
            RootDestination.resolve(
                hasCompletedOnboarding: true,
                isLiveReady: false,
                requiresLegacyCleanupAttention: false
            ) == .mainRecovery,
            "completed install lost the settings recovery surface when health was false"
        )
        try require(
            RootDestination.resolve(
                hasCompletedOnboarding: true,
                isLiveReady: true,
                requiresLegacyCleanupAttention: false
            ) == .mainReady,
            "healthy completed install did not resolve to the ready main state"
        )
        try require(
            RootDestination.resolve(
                hasCompletedOnboarding: false,
                isLiveReady: true,
                requiresLegacyCleanupAttention: false
            ) == .onboarding,
            "incomplete install bypassed onboarding because health happened to be true"
        )
    }

    private static func testLegacyCleanupAttentionOverridesCompletedRouting() throws {
        try require(
            RootDestination.resolve(
                hasCompletedOnboarding: true,
                isLiveReady: true,
                requiresLegacyCleanupAttention: true
            ) == .onboarding,
            "legacy cleanup did not override a completed record"
        )
    }

    private static func testReleaseMissingOnboardingPersistsDisabledControl() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let setupStore = try SetupStore(
            localStore: fixture.store,
            mode: .release
        )
        try require(!setupStore.record.isComplete, "missing release onboarding was marked complete")

        let controlURL = fixture.store.dataURL.appendingPathComponent("control.json")
        try require(
            FileManager.default.fileExists(atPath: controlURL.path),
            "missing release onboarding did not create control.json"
        )
        try require(
            !fixture.store.readControl().protectionEnabled,
            "missing release onboarding did not persist disabled protection"
        )
    }

    private static func testSourceMissingOnboardingPreservesEnabledFallback() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let setupStore = try SetupStore(
            localStore: fixture.store,
            mode: .source
        )
        try require(!setupStore.record.isComplete, "missing source onboarding was marked complete")

        let controlURL = fixture.store.dataURL.appendingPathComponent("control.json")
        try require(
            !FileManager.default.fileExists(atPath: controlURL.path),
            "source onboarding unexpectedly created control.json"
        )
        try require(
            fixture.store.readControl().protectionEnabled,
            "source missing-control fallback no longer defaults to enabled"
        )
    }

    private static func testCompletedReleaseOnboardingPreservesControl() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let completed = OnboardingRecord(
            currentStep: .completion,
            completedSteps: SetupStep.allCases,
            completedAt: "2026-07-17T12:00:00+08:00",
            appVersion: "0.1.0-beta"
        )
        try fixture.store.writeOnboarding(completed)
        _ = try fixture.store.writeControl(enabled: true)

        let setupStore = try SetupStore(
            localStore: fixture.store,
            mode: .release
        )
        try require(setupStore.record.isComplete, "valid release onboarding was not complete")
        try require(
            fixture.store.readControl().protectionEnabled,
            "completed release onboarding unexpectedly disabled protection"
        )
    }
}
