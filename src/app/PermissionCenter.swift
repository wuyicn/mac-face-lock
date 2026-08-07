import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
protocol PermissionProviding: AnyObject {
    func cameraAuthorizationStatus() -> AVAuthorizationStatus
    func isGranted(_ permission: SetupPermission) -> Bool
    func requiresApplicationRestart(for permission: SetupPermission) -> Bool

    func requestCameraAccess() async
    func requestInputMonitoringAccess()
    func requestAccessibilityAccess()
    func requestScreenRecordingAccess()

    @discardableResult
    func open(_ url: URL) -> Bool
}

@MainActor
private final class MacOSPermissionProvider: PermissionProviding {
    private let inputMonitoringGrantedAtLaunch: Bool
    private let screenRecordingGrantedAtLaunch: Bool
    private var restartRequiredPermissions: Set<SetupPermission> = []

    init() {
        inputMonitoringGrantedAtLaunch = CGPreflightListenEventAccess()
        screenRecordingGrantedAtLaunch = CGPreflightScreenCaptureAccess()
    }

    func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func isGranted(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .camera:
            return cameraAuthorizationStatus() == .authorized
        case .inputMonitoring:
            let granted = CGPreflightListenEventAccess()
            if granted && !inputMonitoringGrantedAtLaunch {
                restartRequiredPermissions.insert(.inputMonitoring)
            }
            return granted
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            let granted = CGPreflightScreenCaptureAccess()
            if granted && !screenRecordingGrantedAtLaunch {
                restartRequiredPermissions.insert(.screenRecording)
            }
            return granted
        }
    }

    func requiresApplicationRestart(for permission: SetupPermission) -> Bool {
        restartRequiredPermissions.contains(permission)
    }

    func requestCameraAccess() async {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { _ in
                continuation.resume()
            }
        }
    }

    func requestInputMonitoringAccess() {
        let granted = CGRequestListenEventAccess()
        if granted && !inputMonitoringGrantedAtLaunch {
            restartRequiredPermissions.insert(.inputMonitoring)
        }
    }

    func requestAccessibilityAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecordingAccess() {
        let granted = CGRequestScreenCaptureAccess()
        if granted && !screenRecordingGrantedAtLaunch {
            restartRequiredPermissions.insert(.screenRecording)
        }
    }

    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

private final class PermissionRefreshOwner {
    let notificationCenter: NotificationCenter
    var activationObserver: NSObjectProtocol?
    var timer: Timer?

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        timer?.invalidate()
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
    }
}

@MainActor
final class PermissionCenter {
    private static let generalPrivacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
    )!

    private let provider: PermissionProviding
    private let pollingInterval: TimeInterval
    private let refreshOwner: PermissionRefreshOwner

    private(set) var states: [SetupPermission: PermissionState] = [:]
    private var permissionStepVisible = false

    init(
        provider: PermissionProviding? = nil,
        notificationCenter: NotificationCenter = .default,
        pollingInterval: TimeInterval = 2
    ) {
        self.provider = provider ?? MacOSPermissionProvider()
        self.pollingInterval = pollingInterval
        self.refreshOwner = PermissionRefreshOwner(notificationCenter: notificationCenter)
        self.refreshOwner.activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.refresh()
            }
        }
    }

    @discardableResult
    func refresh() async -> [SetupPermission: PermissionState] {
        var refreshedStates: [SetupPermission: PermissionState] = [
            .camera: Self.mapCameraStatus(provider.cameraAuthorizationStatus()),
        ]

        for permission in [
            SetupPermission.inputMonitoring,
            .accessibility,
            .screenRecording,
        ] {
            refreshedStates[permission] = Self.mapGrant(
                provider.isGranted(permission),
                requiresApplicationRestart: provider.requiresApplicationRestart(for: permission)
            )
        }

        states = refreshedStates
        return refreshedStates
    }

    func requestCamera() async {
        await provider.requestCameraAccess()
        _ = await refresh()
    }

    func requestInputMonitoring() {
        provider.requestInputMonitoringAccess()
        scheduleRefresh()
    }

    func requestAccessibility() {
        provider.requestAccessibilityAccess()
        scheduleRefresh()
    }

    func requestScreenRecording() {
        provider.requestScreenRecordingAccess()
        scheduleRefresh()
    }

    func openSettings(for permission: SetupPermission) {
        let specificURL = Self.settingsURL(for: permission)
        guard !provider.open(specificURL) else {
            return
        }
        _ = provider.open(Self.generalPrivacyURL)
    }

    func setPermissionStepVisible(_ visible: Bool) {
        permissionStepVisible = visible
        if visible {
            guard refreshOwner.timer == nil else {
                return
            }
            scheduleRefresh()
            let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.permissionStepVisible else {
                        return
                    }
                    _ = await self.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshOwner.timer = timer
        } else {
            refreshOwner.timer?.invalidate()
            refreshOwner.timer = nil
        }
    }

    private func scheduleRefresh() {
        Task { @MainActor [weak self] in
            _ = await self?.refresh()
        }
    }

    private static func mapCameraStatus(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .denied
        }
    }

    private static func mapGrant(
        _ granted: Bool,
        requiresApplicationRestart: Bool
    ) -> PermissionState {
        guard granted else {
            return .denied
        }
        return requiresApplicationRestart ? .restartRequired : .granted
    }

    private static func settingsURL(for permission: SetupPermission) -> URL {
        let anchor: String
        switch permission {
        case .camera:
            anchor = "Privacy_Camera"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        )!
    }
}
