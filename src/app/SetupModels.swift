import Foundation

enum SetupStep: String, Codable, CaseIterable, Hashable {
    case preparation
    case permissions
    case enrollment
    case safetyTest = "safety_test"
    case completion
}

enum EnrollmentLifecycle: Equatable {
    case idle
    case running
    case cancelling
}

enum LegacyCleanupState: Equatable {
    case unchecked
    case notRequired
    case confirmationRequired
    case cleaning
    case ambiguous(String)
    case cleanupIncomplete(String)
    case completed
}

enum RootDestination: Equatable {
    case onboarding
    case mainReady
    case mainRecovery

    static func resolve(
        hasCompletedOnboarding: Bool,
        isLiveReady: Bool,
        requiresLegacyCleanupAttention: Bool
    ) -> RootDestination {
        if requiresLegacyCleanupAttention {
            return .onboarding
        }
        guard hasCompletedOnboarding else {
            return .onboarding
        }
        return isLiveReady ? .mainReady : .mainRecovery
    }
}

enum SetupPermission: String, Codable, CaseIterable, Hashable {
    case camera
    case inputMonitoring = "input_monitoring"
    case accessibility
    case screenRecording = "screen_recording"
}

enum PermissionState: String, Codable, Equatable {
    case notDetermined = "not_determined"
    case denied
    case restartRequired = "restart_required"
    case granted
}

enum SetupCheck: String, Codable, CaseIterable, Hashable {
    case cameraPermission = "camera_permission"
    case inputMonitoringPermission = "input_monitoring_permission"
    case accessibilityPermission = "accessibility_permission"
    case screenRecordingPermission = "screen_recording_permission"
    case ownerProfile = "owner_profile"
    case diagnosis
    case ownerTest = "owner_test"
    case serviceHealth = "service_health"
}

struct OnboardingRecord: Codable, Equatable {
    var schemaVersion: Int
    var currentStep: SetupStep
    var completedSteps: [SetupStep]
    var completedAt: String?
    var appVersion: String
    var ownerProfileFingerprint: String?
    var requiresOwnerReverification: Bool?

    init(
        schemaVersion: Int = 1,
        currentStep: SetupStep,
        completedSteps: [SetupStep],
        completedAt: String?,
        appVersion: String,
        ownerProfileFingerprint: String? = nil,
        requiresOwnerReverification: Bool? = false
    ) {
        self.schemaVersion = schemaVersion
        self.currentStep = currentStep
        self.completedSteps = completedSteps
        self.completedAt = completedAt
        self.appVersion = appVersion
        self.ownerProfileFingerprint = ownerProfileFingerprint
        self.requiresOwnerReverification = requiresOwnerReverification
    }

    static let incomplete = OnboardingRecord(
        currentStep: .preparation,
        completedSteps: [],
        completedAt: nil,
        appVersion: ""
    )

    var isComplete: Bool {
        schemaVersion == 1
            && currentStep == .completion
            && completedAt?.isEmpty == false
            && Set(completedSteps).isSuperset(of: Set(SetupStep.allCases))
    }
}

struct SetupReadiness: Equatable {
    let checks: [SetupCheck: Bool]
    let requiredChecks: Set<SetupCheck>

    private init(
        checks: [SetupCheck: Bool],
        requiredChecks: Set<SetupCheck>
    ) {
        self.checks = checks
        self.requiredChecks = requiredChecks
    }

    var canEnableProtection: Bool {
        requiredChecks.allSatisfy { checks[$0] == true }
    }

    static func evaluate(
        permissions: [SetupPermission: PermissionState],
        agentPermissions: [SetupPermission: PermissionState]? = nil,
        ownerProfileValid: Bool,
        diagnosisPassed: Bool,
        ownerTestPassed: Bool,
        serviceHealthy: Bool,
        screenshotEvidenceEnabled: Bool = false
    ) -> SetupReadiness {
        let effectiveAgentPermissions = agentPermissions ?? permissions
        let checks: [SetupCheck: Bool] = [
            .cameraPermission: permissions[.camera] == .granted,
            .inputMonitoringPermission:
                effectiveAgentPermissions[.inputMonitoring] == .granted,
            .accessibilityPermission:
                effectiveAgentPermissions[.accessibility] == .granted,
            .screenRecordingPermission: permissions[.screenRecording] == .granted,
            .ownerProfile: ownerProfileValid,
            .diagnosis: diagnosisPassed,
            .ownerTest: ownerTestPassed,
            .serviceHealth: serviceHealthy,
        ]
        var requiredChecks: Set<SetupCheck> = [
            .cameraPermission,
            .inputMonitoringPermission,
            .accessibilityPermission,
            .ownerProfile,
            .diagnosis,
            .ownerTest,
            .serviceHealth,
        ]
        if screenshotEvidenceEnabled {
            requiredChecks.insert(.screenRecordingPermission)
        }
        return SetupReadiness(
            checks: checks,
            requiredChecks: requiredChecks
        )
    }
}
