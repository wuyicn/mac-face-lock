import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment: Result<AppEnvironment, Error>
    private let permissionCenter: PermissionCenter
    private var localStore: LocalJSONStore?
    private var faceLockStore: FaceLockStore?
    private var setupCoordinator: SetupCoordinator?
    private var themeStore: ThemeStore?
    private var desktopWindowController: DesktopWindowController?
    private var statusMenuController: StatusMenuController?
    private var applicationQuitCoordinator: ApplicationQuitCoordinator?
    private var localMouseMonitor: LocalMouseEventMonitor?

    override init() {
        self.permissionCenter = PermissionCenter()
        do {
            let fileManager = FileManager.default
            guard let applicationSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw AppEnvironmentError.supportDirectoryUnavailable(
                    "Library/Application Support"
                )
            }
            self.environment = .success(
                try AppEnvironment.resolve(
                    arguments: CommandLine.arguments,
                    bundleURL: Bundle.main.bundleURL,
                    applicationSupportURL: applicationSupportURL,
                    fileManager: fileManager
                )
            )
        } catch {
            self.environment = .failure(error)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        localMouseMonitor = LocalMouseEventMonitor(
            recorder: UIEventTraceRecorder.shared
        )
        localMouseMonitor?.start()

        guard case .success(let environment) = environment else {
            guard case .failure(let error) = environment else {
                return
            }
            NSLog("Mac Face Lock 无法启动：%@", error.localizedDescription)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Mac Face Lock 无法启动"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "退出")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let localStore = LocalJSONStore(
            resourcesURL: environment.resourcesURL,
            dataURL: environment.dataURL
        )
        let setupStore: SetupStore
        do {
            setupStore = try SetupStore(
                localStore: localStore,
                mode: environment.mode
            )
        } catch {
            NSLog("Mac Face Lock 无法初始化安全设置：%@", error.localizedDescription)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Mac Face Lock 无法安全启动"
            alert.informativeText = "无法保持保护关闭，请检查应用支持目录权限后重试。"
            alert.addButton(withTitle: "退出")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let setupCoordinator = SetupCoordinator(
            environment: environment,
            permissionCenter: permissionCenter,
            setupStore: setupStore,
            localStore: localStore
        )
        let faceLockStore = FaceLockStore(localStore: localStore)
        let themeStore = ThemeStore(localStore: localStore)
        let desktopWindowController = DesktopWindowController(
            faceLockStore: faceLockStore,
            setupCoordinator: setupCoordinator,
            themeStore: themeStore,
            projectURL: environment.supportURL,
            dataURL: environment.dataURL
        )
        let applicationQuitCoordinator = ApplicationQuitCoordinator(
            stopBackground: {
                await setupCoordinator.stopBackgroundForApplicationQuit()
            },
            terminate: { [weak self] in
                self?.approvePendingApplicationTermination()
            },
            cancelTermination: { [weak self] in
                self?.cancelPendingApplicationTermination()
            },
            cancelDeferredTermination: {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        )
        let statusMenuController = StatusMenuController(
            faceLockStore: faceLockStore,
            setupCoordinator: setupCoordinator,
            projectURL: environment.supportURL,
            dataURL: environment.dataURL,
            showDesktopWindow: { [weak desktopWindowController] in
                desktopWindowController?.show()
            },
            requestApplicationTermination: {
                NSApp.terminate(nil)
            }
        )

        self.localStore = localStore
        self.faceLockStore = faceLockStore
        self.setupCoordinator = setupCoordinator
        self.themeStore = themeStore
        self.desktopWindowController = desktopWindowController
        self.statusMenuController = statusMenuController
        self.applicationQuitCoordinator = applicationQuitCoordinator

        if !setupCoordinator.hasCompletedOnboarding {
            desktopWindowController.show()
        }
        Task {
            await setupCoordinator.inspectLegacyInstall()
            if setupCoordinator.requiresLegacyCleanupAttention {
                desktopWindowController.show()
            }
            await setupCoordinator.refreshLiveReadiness()
            faceLockStore.startPolling()
            statusMenuController.startRefreshing()
            faceLockStore.refresh()
            statusMenuController.refresh()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        desktopWindowController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let applicationQuitCoordinator else {
            return .terminateNow
        }

        switch applicationQuitCoordinator.applicationShouldTerminate(
            confirm: confirmApplicationTermination
        ) {
        case .terminateCancel:
            return .terminateCancel
        case .terminateLater:
            return .terminateLater
        case .terminateNow:
            return .terminateNow
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        UIEventTraceRecorder.shared.record(.appActivation)
        Task {
            await setupCoordinator?.refreshLiveReadiness()
            faceLockStore?.refresh()
            statusMenuController?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localMouseMonitor?.stop()
        localMouseMonitor = nil
        faceLockStore?.stopPolling()
        statusMenuController?.stopRefreshing()
    }

    private func confirmApplicationTermination() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 Mac Face Lock 并停止保护？"
        alert.informativeText = "退出后，保护将停止，后台保护也会关闭。再次打开 Mac Face Lock 前，此 Mac 不会继续受到保护。"
        alert.addButton(withTitle: "退出并停止保护")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func approvePendingApplicationTermination() {
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func cancelPendingApplicationTermination() {
        NSApp.reply(toApplicationShouldTerminate: false)
        desktopWindowController?.show()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "未能停止后台保护"
        alert.informativeText = setupCoordinator?.currentError
            ?? "保护已关闭，但后台保护尚未确认停止。请在控制中心修复后重试退出。"
        alert.addButton(withTitle: "返回控制中心")
        alert.runModal()
    }
}
