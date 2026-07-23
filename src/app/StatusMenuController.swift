import AppKit
import Foundation

@MainActor
final class StatusMenuController: NSObject {
    private(set) var statusItem: NSStatusItem

    private let faceLockStore: FaceLockStore
    private let setupCoordinator: SetupCoordinator
    private let applicationQuitCoordinator: ApplicationQuitCoordinator
    private let projectURL: URL
    private let dataURL: URL
    private let showDesktopWindow: () -> Void
    private var refreshTimer: Timer?

    init(
        faceLockStore: FaceLockStore,
        setupCoordinator: SetupCoordinator,
        applicationQuitCoordinator: ApplicationQuitCoordinator,
        projectURL: URL,
        dataURL: URL,
        showDesktopWindow: @escaping () -> Void
    ) {
        self.faceLockStore = faceLockStore
        self.setupCoordinator = setupCoordinator
        self.applicationQuitCoordinator = applicationQuitCoordinator
        self.projectURL = projectURL
        self.dataURL = dataURL
        self.showDesktopWindow = showDesktopWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        refresh()
    }

    func startRefreshing() {
        guard refreshTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let presentation = present(faceLockStore.state)
        statusItem.button?.title = presentation.menuTitle

        let menu = NSMenu()
        menu.addItem(disabledItem("状态：\(presentation.headline)"))
        menu.addItem(disabledItem("当前动作：\(faceLockStore.state.action ?? "无")"))
        menu.addItem(disabledItem("更新时间：\(faceLockStore.state.updatedAt ?? "无")"))
        menu.addItem(.separator())
        menu.addItem(actionItem("打开控制中心", action: #selector(openControlCenter), key: "o"))
        if setupCoordinator.hasCompletedOnboarding && setupCoordinator.isLiveReady {
            menu.addItem(actionItem(
                faceLockStore.protectionEnabled ? "暂停保护" : "恢复保护",
                action: #selector(toggleProtection),
                key: "p"
            ))
        } else if setupCoordinator.hasCompletedOnboarding {
            menu.addItem(actionItem(
                "检查与修复保护",
                action: #selector(openControlCenter),
                key: "p"
            ))
        } else {
            menu.addItem(actionItem(
                "完成首次安全设置",
                action: #selector(openControlCenter),
                key: "p"
            ))
        }
        menu.addItem(actionItem("刷新状态", action: #selector(refreshFromMenu), key: "r"))
        menu.addItem(actionItem("打开证据目录", action: #selector(openEvidence), key: "e"))
        menu.addItem(actionItem("打开日志", action: #selector(openLog), key: "l"))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            "退出 Mac Face Lock 并停止保护",
            action: #selector(quitAndStopProtection),
            key: "q"
        ))
        statusItem.menu = menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openControlCenter() {
        showDesktopWindow()
    }

    @objc private func toggleProtection() {
        if faceLockStore.protectionEnabled {
            faceLockStore.setProtectionEnabled(false)
            refresh()
            return
        }
        Task {
            do {
                try await setupCoordinator.enableProtection()
                faceLockStore.refresh()
            } catch {
                showDesktopWindow()
            }
            refresh()
        }
    }

    @objc private func refreshFromMenu() {
        faceLockStore.refresh()
        refresh()
    }

    @objc private func openEvidence() {
        NSWorkspace.shared.open(
            dataURL.appendingPathComponent("evidence", isDirectory: true)
        )
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(projectURL.appendingPathComponent("logs/agent.log"))
    }

    @objc private func quitAndStopProtection() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 Mac Face Lock 并停止保护？"
        alert.informativeText = "退出后，保护将停止，后台保护也会关闭。再次打开 Mac Face Lock 前，此 Mac 不会继续受到保护。"
        alert.addButton(withTitle: "退出并停止保护")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task {
            let didQuit = await applicationQuitCoordinator.requestQuit()
            guard !didQuit else {
                return
            }
            showDesktopWindow()
            NSApp.activate(ignoringOtherApps: true)
            let failureAlert = NSAlert()
            failureAlert.alertStyle = .critical
            failureAlert.messageText = "未能停止后台保护"
            failureAlert.informativeText = setupCoordinator.currentError
                ?? "保护已关闭，但后台保护尚未确认停止。请在控制中心修复后重试退出。"
            failureAlert.addButton(withTitle: "返回控制中心")
            failureAlert.runModal()
        }
    }
}
