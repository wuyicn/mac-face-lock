import Combine
import Foundation

private final class PollingTimerOwner {
    var timer: Timer?

    deinit {
        timer?.invalidate()
    }
}

@MainActor
final class FaceLockStore: ObservableObject {
    @Published private(set) var state: FaceLockState
    @Published private(set) var activities: [ActivityEvent]
    @Published private(set) var protectionEnabled: Bool
    @Published private(set) var lastError: String?

    private let localStore: LocalJSONStore
    private let pollingTimer = PollingTimerOwner()

    init(localStore: LocalJSONStore) {
        self.localStore = localStore
        self.state = localStore.readState()
        self.activities = localStore.readActivities()
        self.protectionEnabled = localStore.readControl().protectionEnabled
        self.lastError = nil
    }

    func startPolling() {
        guard pollingTimer.timer == nil else {
            return
        }

        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer.timer = timer
    }

    func stopPolling() {
        pollingTimer.timer?.invalidate()
        pollingTimer.timer = nil
    }

    func refresh() {
        state = localStore.readState()
        activities = localStore.readActivities()
        protectionEnabled = localStore.readControl().protectionEnabled
    }

    func setProtectionEnabled(_ enabled: Bool) {
        do {
            let control = try localStore.writeControl(enabled: enabled)
            protectionEnabled = control.protectionEnabled
            lastError = nil
        } catch {
            lastError = "无法更新保护状态，请检查本地文件权限后重试。"
        }
    }
}
