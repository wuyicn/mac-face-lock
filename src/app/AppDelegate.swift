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
        NSApp.setActivationPolicy(.accessory)

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
            themeStore: themeStore,
            projectURL: environment.supportURL,
            dataURL: environment.dataURL
        )
        let statusMenuController = StatusMenuController(
            faceLockStore: faceLockStore,
            projectURL: environment.supportURL,
            dataURL: environment.dataURL,
            showDesktopWindow: { [weak desktopWindowController] in
                desktopWindowController?.show()
            }
        )

        self.localStore = localStore
        self.faceLockStore = faceLockStore
        self.setupCoordinator = setupCoordinator
        self.themeStore = themeStore
        self.desktopWindowController = desktopWindowController
        self.statusMenuController = statusMenuController

        faceLockStore.startPolling()
        statusMenuController.startRefreshing()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        desktopWindowController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        faceLockStore?.stopPolling()
        statusMenuController?.stopRefreshing()
    }
}
