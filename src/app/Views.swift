import AppKit
import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "保护"
    case activity = "记录"
    case settings = "设置"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview:
            return "checkmark.shield"
        case .activity:
            return "clock"
        case .settings:
            return "gearshape"
        }
    }
}

struct RootView: View {
    @ObservedObject var faceLockStore: FaceLockStore
    @ObservedObject var setupCoordinator: SetupCoordinator
    @ObservedObject var themeStore: ThemeStore
    let projectURL: URL
    let dataURL: URL
    @State private var selection: AppSection = .overview

    private var status: StatusPresentation {
        present(faceLockStore.state)
    }

    var body: some View {
        Group {
            if RootDestination.resolve(
                hasCompletedOnboarding: setupCoordinator.hasCompletedOnboarding,
                isLiveReady: setupCoordinator.isLiveReady
            ) == .main {
                mainInterface
            } else {
                OnboardingView(
                    setupCoordinator: setupCoordinator,
                    themeStore: themeStore
                )
            }
        }
    }

    private var mainInterface: some View {
        GeometryReader { geometry in
            ZStack {
                windowBackdrop

                VStack(spacing: 0) {
                    if !setupCoordinator.isLiveReady {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(Color(nsColor: .systemOrange))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("首次设置已完成，当前安全状态尚未全部确认")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("保护恢复前会重新检查当前权限、本人资料和 Agent 状态。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("前往设置") {
                                selection = .settings
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 58)
                        .background(.regularMaterial)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color(nsColor: .systemOrange).opacity(0.45))
                                .frame(height: 1)
                        }
                    }

                    HStack(spacing: 0) {
                        SidebarView(
                            selection: $selection,
                            accentColor: themeStore.accentColor
                        )
                        .frame(width: 210)

                        sectionContent
                            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                        if selection == .overview, geometry.size.width >= 1050 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.10))
                                .frame(width: 1)
                                .overlay(Color.white.opacity(0.06))

                            PolicyInspector()
                                .frame(width: 300)
                        }
                    }
                }
            }
        }
        .tint(themeStore.accentColor)
        .preferredColorScheme(themeStore.preferredColorScheme)
    }

    private var windowBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    themeStore.accentColor.opacity(0.16),
                    Color.clear,
                    themeStore.accentColor.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .overview:
            OverviewView(
                faceLockStore: faceLockStore,
                setupCoordinator: setupCoordinator,
                accentColor: themeStore.accentColor,
                selection: $selection
            )
        case .activity:
            ActivityView(
                activities: faceLockStore.activities,
                accentColor: themeStore.accentColor,
                projectURL: projectURL,
                dataURL: dataURL
            )
        case .settings:
            SettingsView(
                setupCoordinator: setupCoordinator,
                faceLockStore: faceLockStore,
                themeStore: themeStore
            )
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: AppSection
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    Image(systemName: "faceid")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(StatusSeverity.safe.color)
                }
                .frame(width: 68, height: 68)

                Text("Mac 人脸保护")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 58)
            .padding(.bottom, 42)

            VStack(spacing: 8) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(section.rawValue)
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(selection == section ? accentColor : Color.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background {
                            if selection == section {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(accentColor.opacity(0.15))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                    }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.rawValue)
                    .accessibilityValue(selection == section ? "已选择" : "未选择")
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)

            Spacer()
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
                .overlay(Color.white.opacity(0.06))
        }
    }
}

private struct OverviewView: View {
    @ObservedObject var faceLockStore: FaceLockStore
    @ObservedObject var setupCoordinator: SetupCoordinator
    let accentColor: Color
    @Binding var selection: AppSection

    private var status: StatusPresentation {
        present(faceLockStore.state)
    }

    private var todayActivities: ArraySlice<ActivityEvent> {
        faceLockStore.activities.filter { event in
            guard let date = parseTimestamp(event.timestamp) else {
                return false
            }
            return Calendar.current.isDateInToday(date)
        }.prefix(4)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                statusHeader

                Divider()
                    .overlay(Color.white.opacity(0.08))

                Text("今天")
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 0) {
                    if todayActivities.isEmpty {
                        CurrentStateTimelineRow(
                            state: faceLockStore.state,
                            presentation: status,
                            accentColor: accentColor
                        )
                    } else {
                        ForEach(Array(todayActivities.enumerated()), id: \.element.id) { index, event in
                            ActivityTimelineRow(
                                event: event,
                                accentColor: accentColor,
                                highlighted: index == 0
                            )
                        }
                    }
                }

                Button {
                    selection = .activity
                } label: {
                    Label("查看全部记录", systemImage: "doc.text")
                        .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentColor)
                .padding(.top, 2)
            }
            .padding(.horizontal, 38)
            .padding(.top, 62)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: status.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(status.severity.color)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 6) {
                Text(status.headline)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(status.severity.color)
                Text(status.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 8) {
                Button(faceLockStore.protectionEnabled ? "暂停保护" : "恢复保护") {
                    if faceLockStore.protectionEnabled {
                        faceLockStore.setProtectionEnabled(false)
                    } else {
                        Task {
                            try? await setupCoordinator.enableProtection()
                            faceLockStore.refresh()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let error = faceLockStore.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 230, alignment: .trailing)
                }
            }
        }
    }
}

private struct CurrentStateTimelineRow: View {
    let state: FaceLockState
    let presentation: StatusPresentation
    let accentColor: Color

    var body: some View {
        TimelineRowShell(
            symbol: presentation.symbol,
            color: presentation.severity.color,
            time: state.updatedAt.map(localizedTime) ?? "当前",
            title: presentation.headline,
            detail: presentation.detail,
            metadata: metadataText(
                ownerHits: state.ownerHits,
                strangerHits: state.strangerHits,
                noFaceHits: state.noFaceHits,
                framesChecked: state.framesChecked
            ),
            highlighted: true,
            accentColor: accentColor
        )
    }
}

private struct ActivityTimelineRow: View {
    let event: ActivityEvent
    let accentColor: Color
    let highlighted: Bool

    private var visual: EventVisual {
        EventVisual(event: event, accentColor: accentColor)
    }

    var body: some View {
        TimelineRowShell(
            symbol: visual.symbol,
            color: visual.color,
            time: localizedTime(event.timestamp),
            title: event.title,
            detail: event.detail,
            metadata: metadataText(
                ownerHits: event.metadata.ownerHits,
                strangerHits: event.metadata.strangerHits,
                noFaceHits: event.metadata.noFaceHits,
                framesChecked: event.metadata.framesChecked
            ),
            highlighted: highlighted,
            accentColor: accentColor
        )
    }
}

private struct TimelineRowShell: View {
    let symbol: String
    let color: Color
    let time: String
    let title: String
    let detail: String
    let metadata: String?
    let highlighted: Bool
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.18))
                    Circle()
                        .stroke(color.opacity(0.70), lineWidth: 1)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 38, height: 38)

                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: highlighted ? 64 : 38)
            }

            Text(time)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, highlighted ? 16 : 8)
        }
        .padding(.horizontal, highlighted ? 14 : 0)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(accentColor.opacity(0.16), lineWidth: 1)
                    }
            }
        }
    }
}

private struct PolicyInspector: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("当前策略")
                .font(.system(size: 22, weight: .bold))
                .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 0) {
                PolicyStep(number: 1, symbol: "clock", title: "空闲 60 秒", color: .green)
                PolicyStep(number: 2, symbol: "keyboard", title: "输入触发验证", color: .green)
                PolicyStep(number: 3, symbol: "lock", title: "非本人锁屏", color: .orange, showsLine: false)
            }

            Divider()
                .padding(.vertical, 28)

            PolicyNote(symbol: "camera", text: "相机不可用时保持解锁", color: .green)
            PolicyNote(symbol: "timer", text: "锁屏后冷却 5 分钟", color: .orange)

            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.top, 68)
        .background(.ultraThinMaterial)
    }
}

private struct PolicyStep: View {
    let number: Int
    let symbol: String
    let title: String
    let color: Color
    var showsLine = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text("\(number)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.12), in: Circle())
                if showsLine {
                    Rectangle()
                        .fill(Color.primary.opacity(0.20))
                        .frame(width: 1, height: 38)
                }
            }

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(color)
            }
            .frame(width: 44, height: 44)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 12)
        }
    }
}

private struct PolicyNote: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)

            Text(text)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

private struct ActivityView: View {
    let activities: [ActivityEvent]
    let accentColor: Color
    let projectURL: URL
    let dataURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("活动记录")
                            .font(.system(size: 30, weight: .bold))
                        Text(activities.isEmpty ? "尚无结构化活动记录" : "最近 \(activities.count) 条本地活动")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("打开证据目录") {
                        WorkspaceLinks.openEvidence(dataURL: dataURL)
                    }
                    .buttonStyle(.bordered)

                    Button("打开日志") {
                        WorkspaceLinks.openLog(projectURL: projectURL)
                    }
                    .buttonStyle(.bordered)
                }

                if activities.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text("关键验证事件将在这里按时间倒序显示")
                            .font(.headline)
                        Text("证据照片不会在界面中自动加载。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 70)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(activities) { event in
                            ActivityRecordRow(event: event, accentColor: accentColor)
                        }
                    }
                }
            }
            .padding(.horizontal, 42)
            .padding(.top, 62)
            .padding(.bottom, 42)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActivityRecordRow: View {
    let event: ActivityEvent
    let accentColor: Color

    private var visual: EventVisual {
        EventVisual(event: event, accentColor: accentColor)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle()
                    .fill(visual.color.opacity(0.15))
                Image(systemName: visual.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(visual.color)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text(localizedDateAndTime(event.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(event.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata = metadataText(
                    ownerHits: event.metadata.ownerHits,
                    strangerHits: event.metadata.strangerHits,
                    noFaceHits: event.metadata.noFaceHits,
                    framesChecked: event.metadata.framesChecked
                ) {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct EventVisual {
    let symbol: String
    let color: Color

    init(event: ActivityEvent, accentColor: Color) {
        switch event.type {
        case "owner_verified":
            symbol = "person.crop.circle.badge.checkmark"
            color = Color(nsColor: .systemGreen)
        case "protection_armed":
            symbol = "shield.lefthalf.filled"
            color = Color(nsColor: .systemOrange)
        case "verification_failed":
            symbol = "person.crop.circle.badge.exclamationmark"
            color = Color(nsColor: .systemOrange)
        case "camera_unavailable":
            symbol = "video.slash.fill"
            color = Color(nsColor: .systemOrange)
        case "screen_locked":
            symbol = "lock.fill"
            color = Color(nsColor: .systemRed)
        case "protection_paused":
            symbol = "pause.circle.fill"
            color = Color(nsColor: .systemOrange)
        case "protection_resumed":
            symbol = "play.circle.fill"
            color = accentColor
        default:
            symbol = "clock.fill"
            switch event.severity {
            case "success":
                color = Color(nsColor: .systemGreen)
            case "warning":
                color = Color(nsColor: .systemOrange)
            case "critical":
                color = Color(nsColor: .systemRed)
            default:
                color = accentColor
            }
        }
    }
}

private enum WorkspaceLinks {
    static func openEvidence(dataURL: URL) {
        NSWorkspace.shared.open(dataURL.appendingPathComponent("evidence", isDirectory: true))
    }

    static func openLog(projectURL: URL) {
        NSWorkspace.shared.open(projectURL.appendingPathComponent("logs/agent.log"))
    }
}

private func parseTimestamp(_ timestamp: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: timestamp) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: timestamp)
}

private func localizedTime(_ timestamp: String) -> String {
    guard let date = parseTimestamp(timestamp) else {
        return timestamp
    }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
}

private func localizedDateAndTime(_ timestamp: String) -> String {
    guard let date = parseTimestamp(timestamp) else {
        return timestamp
    }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func metadataText(
    ownerHits: Int?,
    strangerHits: Int?,
    noFaceHits: Int?,
    framesChecked: Int?
) -> String? {
    var parts: [String] = []
    if let ownerHits {
        parts.append("\(ownerHits) 次本人")
    }
    if let strangerHits {
        parts.append("\(strangerHits) 次陌生人")
    }
    if let noFaceHits {
        parts.append("\(noFaceHits) 次无人脸")
    }
    if let framesChecked {
        parts.append("\(framesChecked) 帧")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
}
