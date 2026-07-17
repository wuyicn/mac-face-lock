import AppKit
import SwiftUI

@MainActor
final class DesktopWindowController {
    let window: NSWindow

    private var hasCenteredWindow = false

    init(
        faceLockStore: FaceLockStore,
        setupCoordinator: SetupCoordinator,
        themeStore: ThemeStore,
        projectURL: URL,
        dataURL: URL
    ) {
        let contentView = RootView(
            faceLockStore: faceLockStore,
            setupCoordinator: setupCoordinator,
            themeStore: themeStore,
            projectURL: projectURL,
            dataURL: dataURL
        )
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Face Lock"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setFrame(NSRect(x: 0, y: 0, width: 1180, height: 760), display: false)
        self.window = window
    }

    func show() {
        if !hasCenteredWindow {
            window.center()
            hasCenteredWindow = true
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
