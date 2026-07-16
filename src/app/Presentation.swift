import SwiftUI

enum StatusSeverity {
    case safe
    case neutral
    case warning
    case critical

    var color: Color {
        switch self {
        case .safe:
            return Color(nsColor: .systemGreen)
        case .neutral:
            return .secondary
        case .warning:
            return Color(nsColor: .systemOrange)
        case .critical:
            return Color(nsColor: .systemRed)
        }
    }
}

struct StatusPresentation {
    let menuTitle: String
    let headline: String
    let detail: String
    let symbol: String
    let severity: StatusSeverity
}

func present(_ state: FaceLockState) -> StatusPresentation {
    switch state.status {
    case "missing":
        return StatusPresentation(
            menuTitle: "脸锁:无状态",
            headline: "暂无状态",
            detail: "尚未读取到脸锁运行状态。",
            symbol: "questionmark.circle",
            severity: .neutral
        )
    case "paused":
        return StatusPresentation(
            menuTitle: "脸锁:暂停",
            headline: "保护已暂停",
            detail: "输入活动不会触发身份验证或锁屏。",
            symbol: "pause.circle.fill",
            severity: .warning
        )
    case "running", "active":
        return StatusPresentation(
            menuTitle: "脸锁:运行",
            headline: "保护运行中",
            detail: "正在监控 Mac 的使用状态。",
            symbol: "checkmark.shield.fill",
            severity: .safe
        )
    case "armed":
        return StatusPresentation(
            menuTitle: "脸锁:布防",
            headline: "已进入布防",
            detail: "检测到输入后将验证当前用户。",
            symbol: "shield.lefthalf.filled",
            severity: .warning
        )
    case "verifying":
        return StatusPresentation(
            menuTitle: "脸锁:验证中",
            headline: "正在验证身份",
            detail: "正在确认当前使用者是否为本人。",
            symbol: "person.crop.circle.badge.questionmark",
            severity: .neutral
        )
    case "verified":
        if state.action == "allow_final_camera_evidence" {
            return StatusPresentation(
                menuTitle: "脸锁:已验证",
                headline: "已确认本人",
                detail: "最终照片确认本人，已取消锁屏。",
                symbol: "person.crop.circle.badge.checkmark",
                severity: .safe
            )
        }
        if let decision = state.lastDecision,
           ["stranger", "no_face", "unknown"].contains(decision) {
            let detail: String
            switch decision {
            case "stranger":
                detail = "当前使用者不是本人。"
            case "no_face":
                detail = "未检测到可确认的人脸。"
            default:
                detail = "未能确认当前使用者。"
            }
            return StatusPresentation(
                menuTitle: "脸锁:已验证",
                headline: "验证未通过",
                detail: detail,
                symbol: "person.crop.circle.badge.exclamationmark",
                severity: .critical
            )
        }
        return StatusPresentation(
            menuTitle: "脸锁:已验证",
            headline: state.lastDecision == "owner" ? "已确认本人" : "验证已完成",
            detail: state.lastDecision == "owner" ? "已保持解锁，保护继续运行。" : "正在处理验证结果。",
            symbol: "person.crop.circle.badge.checkmark",
            severity: .safe
        )
    case "camera_unavailable":
        return StatusPresentation(
            menuTitle: "脸锁:相机异常",
            headline: "相机不可用，已保持解锁",
            detail: "未触发锁屏，请检查相机连接和权限。",
            symbol: "video.slash.fill",
            severity: .warning
        )
    case "locking":
        if state.mode == "observe" {
            return StatusPresentation(
                menuTitle: "脸锁:模拟锁屏",
                headline: "正在模拟锁屏",
                detail: "观察模式不会真正锁定 Mac。",
                symbol: "eye.fill",
                severity: .warning
            )
        }
        return StatusPresentation(
            menuTitle: "脸锁:锁屏中",
            headline: "正在锁定屏幕",
            detail: lockDetail(for: state),
            symbol: "lock.fill",
            severity: .critical
        )
    case "locked":
        if state.mode == "observe" {
            return StatusPresentation(
                menuTitle: "脸锁:模拟锁屏",
                headline: "已模拟锁屏",
                detail: "观察模式未执行真实系统锁屏。",
                symbol: "eye.fill",
                severity: .warning
            )
        }
        return StatusPresentation(
            menuTitle: "脸锁:已锁",
            headline: "已触发锁屏",
            detail: lockDetail(for: state),
            symbol: "lock.fill",
            severity: .critical
        )
    case "lock_error":
        return StatusPresentation(
            menuTitle: "脸锁:锁屏失败",
            headline: "系统锁屏失败",
            detail: "未能完成锁屏，请检查日志后重试。",
            symbol: "lock.slash.fill",
            severity: .critical
        )
    case "event_queued":
        if state.lockSucceeded == false {
            return StatusPresentation(
                menuTitle: "脸锁:锁屏失败",
                headline: "系统锁屏失败",
                detail: "系统锁屏未完成，失败通知已排队。",
                symbol: "lock.slash.fill",
                severity: .critical
            )
        }
        if state.lockSucceeded == true {
            return StatusPresentation(
                menuTitle: "脸锁:通知已排队",
                headline: "锁屏通知已排队",
                detail: "系统锁屏已完成，通知已进入队列。",
                symbol: "tray.and.arrow.down.fill",
                severity: .neutral
            )
        }
        return StatusPresentation(
            menuTitle: "脸锁:通知已排队",
            headline: "锁屏通知已排队",
            detail: state.action == "lock"
                ? "通知已排队，系统锁屏结果待确认。"
                : "本地事件已进入通知队列。",
            symbol: "tray.and.arrow.down.fill",
            severity: state.action == "lock" ? .warning : .neutral
        )
    case "event_notify_error":
        if state.lockSucceeded == false {
            return StatusPresentation(
                menuTitle: "脸锁:锁屏失败",
                headline: "系统锁屏失败",
                detail: "系统锁屏未完成，且失败通知写入失败。",
                symbol: "lock.slash.fill",
                severity: .critical
            )
        }
        if state.lockSucceeded == true {
            return StatusPresentation(
                menuTitle: "脸锁:通知异常",
                headline: "通知写入失败",
                detail: "系统锁屏已完成，但通知写入失败。",
                symbol: "exclamationmark.bubble.fill",
                severity: .warning
            )
        }
        return StatusPresentation(
            menuTitle: "脸锁:通知异常",
            headline: "通知写入失败",
            detail: state.action == "lock"
                ? "通知写入失败，系统锁屏结果待确认。"
                : "请检查本地事件通知层。",
            symbol: "exclamationmark.bubble.fill",
            severity: .warning
        )
    case "input_listener_error":
        return StatusPresentation(
            menuTitle: "脸锁:监听异常",
            headline: "输入监听异常",
            detail: "暂时无法可靠检测键盘或鼠标输入。",
            symbol: "exclamationmark.triangle.fill",
            severity: .critical
        )
    case "stopped":
        if state.action == "restart_required" {
            return StatusPresentation(
                menuTitle: "脸锁:监听异常",
                headline: "输入监听异常，服务已停止",
                detail: "服务正在等待 launchd 重启。",
                symbol: "exclamationmark.triangle.fill",
                severity: .critical
            )
        }
        if state.action == "lock", state.mode != "observe" {
            return StatusPresentation(
                menuTitle: "脸锁:锁屏失败",
                headline: "锁屏失败，服务已停止",
                detail: "保护服务在完成系统锁屏前停止。",
                symbol: "lock.slash.fill",
                severity: .critical
            )
        }
        return StatusPresentation(
            menuTitle: "脸锁:已停止",
            headline: "保护服务已停止",
            detail: "保护服务当前未运行。",
            symbol: "stop.circle.fill",
            severity: .warning
        )
    default:
        return StatusPresentation(
            menuTitle: "脸锁:\(state.status)",
            headline: "状态：\(state.status)",
            detail: state.lastReason ?? "正在等待下一次状态更新。",
            symbol: "questionmark.circle",
            severity: .neutral
        )
    }
}

private func lockDetail(for state: FaceLockState) -> String {
    guard let reason = state.lockReason, !reason.isEmpty else {
        return "识别结果已触发安全锁屏。"
    }
    return "锁屏原因：\(reason)"
}
