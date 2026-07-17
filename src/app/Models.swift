import Foundation

struct FaceLockState: Codable, Equatable {
    var status: String
    var mode: String?
    var armed: Bool
    var action: String?
    var heartbeat: String?
    var updatedAt: String?
    var systemIdleSeconds: Double?
    var lastDecision: String?
    var lastReason: String?
    var ownerHits: Int?
    var strangerHits: Int?
    var noFaceHits: Int?
    var framesChecked: Int?
    var lockReason: String?
    var lockSucceeded: Bool?
    var agentPid: Int32?
    var cameraReady: Bool?
    var inputMonitoringReady: Bool?
    var accessibilityReady: Bool?

    init(
        status: String,
        mode: String? = nil,
        armed: Bool,
        action: String? = nil,
        heartbeat: String? = nil,
        updatedAt: String? = nil,
        systemIdleSeconds: Double? = nil,
        lastDecision: String? = nil,
        lastReason: String? = nil,
        ownerHits: Int? = nil,
        strangerHits: Int? = nil,
        noFaceHits: Int? = nil,
        framesChecked: Int? = nil,
        lockReason: String? = nil,
        lockSucceeded: Bool? = nil,
        agentPid: Int32? = nil,
        cameraReady: Bool? = nil,
        inputMonitoringReady: Bool? = nil,
        accessibilityReady: Bool? = nil
    ) {
        self.status = status
        self.mode = mode
        self.armed = armed
        self.action = action
        self.heartbeat = heartbeat
        self.updatedAt = updatedAt
        self.systemIdleSeconds = systemIdleSeconds
        self.lastDecision = lastDecision
        self.lastReason = lastReason
        self.ownerHits = ownerHits
        self.strangerHits = strangerHits
        self.noFaceHits = noFaceHits
        self.framesChecked = framesChecked
        self.lockReason = lockReason
        self.lockSucceeded = lockSucceeded
        self.agentPid = agentPid
        self.cameraReady = cameraReady
        self.inputMonitoringReady = inputMonitoringReady
        self.accessibilityReady = accessibilityReady
    }

    static let missing = FaceLockState(status: "missing", armed: false)
}

struct ActivityMetadata: Codable, Equatable {
    var ownerHits: Int?
    var strangerHits: Int?
    var noFaceHits: Int?
    var framesChecked: Int?
    var reason: String?

    init(
        ownerHits: Int? = nil,
        strangerHits: Int? = nil,
        noFaceHits: Int? = nil,
        framesChecked: Int? = nil,
        reason: String? = nil
    ) {
        self.ownerHits = ownerHits
        self.strangerHits = strangerHits
        self.noFaceHits = noFaceHits
        self.framesChecked = framesChecked
        self.reason = reason
    }
}

struct ActivityEvent: Codable, Identifiable, Equatable {
    var schemaVersion: Int
    var id: String
    var timestamp: String
    var type: String
    var title: String
    var detail: String
    var severity: String
    var metadata: ActivityMetadata
}

struct ControlFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var protectionEnabled: Bool
    var updatedAt: String

    static let enabledFallback = ControlFile(
        protectionEnabled: true,
        updatedAt: ""
    )
}

enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

enum AccentTheme: String, Codable, CaseIterable {
    case oceanBlue
    case guardianGreen
    case amethyst
}

struct UIPreferences: Codable, Equatable {
    var schemaVersion: Int = 1
    var appearance: AppearanceMode = .system
    var accent: AccentTheme = .oceanBlue
}
