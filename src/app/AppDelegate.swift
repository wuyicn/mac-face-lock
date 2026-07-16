import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let projectLocation: Result<ProjectLocation, ProjectLocatorError>
    private var localStore: LocalJSONStore?
    private var faceLockStore: FaceLockStore?
    private var themeStore: ThemeStore?
    private var desktopWindowController: DesktopWindowController?
    private var statusMenuController: StatusMenuController?

    override init() {
        do {
            self.projectLocation = .success(
                try ProjectLocator.locate(arguments: CommandLine.arguments)
            )
        } catch let error as ProjectLocatorError {
            self.projectLocation = .failure(error)
        } catch {
            preconditionFailure("ProjectLocator threw an unexpected error: \(error)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard case .success(let location) = projectLocation else {
            guard case .failure(let error) = projectLocation else {
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
            projectURL: location.projectURL,
            dataURL: location.dataURL
        )
        let faceLockStore = FaceLockStore(localStore: localStore)
        let themeStore = ThemeStore(localStore: localStore)
        let desktopWindowController = DesktopWindowController(
            faceLockStore: faceLockStore,
            themeStore: themeStore,
            projectURL: location.projectURL,
            dataURL: location.dataURL
        )
        let statusMenuController = StatusMenuController(
            faceLockStore: faceLockStore,
            projectURL: location.projectURL,
            dataURL: location.dataURL,
            showDesktopWindow: { [weak desktopWindowController] in
                desktopWindowController?.show()
            }
        )

        self.localStore = localStore
        self.faceLockStore = faceLockStore
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
