import AppKit
import Foundation

@MainActor
final class StatusMenuController: NSObject {
    private(set) var statusItem: NSStatusItem

    private let faceLockStore: FaceLockStore
    private let projectURL: URL
    private let dataURL: URL
    private let showDesktopWindow: () -> Void
    private var refreshTimer: Timer?

    init(
        faceLockStore: FaceLockStore,
        projectURL: URL,
        dataURL: URL,
        showDesktopWindow: @escaping () -> Void
    ) {
        self.faceLockStore = faceLockStore
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
        menu.addItem(actionItem(
            faceLockStore.protectionEnabled ? "暂停保护" : "恢复保护",
            action: #selector(toggleProtection),
            key: "p"
        ))
        menu.addItem(actionItem("刷新状态", action: #selector(refreshFromMenu), key: "r"))
        menu.addItem(actionItem("打开证据目录", action: #selector(openEvidence), key: "e"))
        menu.addItem(actionItem("打开日志", action: #selector(openLog), key: "l"))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出界面", action: #selector(quitInterface), key: "q"))
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
        faceLockStore.setProtectionEnabled(!faceLockStore.protectionEnabled)
        refresh()
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

    @objc private func quitInterface() {
        NSApp.terminate(nil)
    }
}
