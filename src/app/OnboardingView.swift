import Combine
import SwiftUI

enum CustomerActionState: Equatable {
    case idle
    case working(String)
    case success(String)
    case failure(String)
}

struct CustomerActionStatusView: View {
    let state: CustomerActionState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working(let message):
            Label(message, systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var setupCoordinator: SetupCoordinator
    @ObservedObject var themeStore: ThemeStore
    @State private var actionState: CustomerActionState = .idle
    @State private var isConfirmingOrphanRecovery = false

    private let orderedSteps: [(SetupStep, String, String)] = [
        (.preparation, "准备检查", "checklist"),
        (.permissions, "权限中心", "hand.raised"),
        (.enrollment, "录入本人", "faceid"),
        (.safetyTest, "权限确认", "checkmark.shield"),
        (.completion, "完成并开启", "checkmark.shield"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            stepSidebar
                .frame(width: 250)

            ZStack {
                LinearGradient(
                    colors: [
                        themeStore.accentColor.opacity(0.12),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        stepContent
                    }
                    .padding(.horizontal, 54)
                    .padding(.vertical, 50)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .tint(themeStore.accentColor)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            updatePermissionPolling(for: setupCoordinator.currentStep)
        }
        .onDisappear {
            setupCoordinator.setPermissionStepVisible(false)
        }
        .onChange(of: setupCoordinator.currentStep) { newStep in
            actionState = .idle
            updatePermissionPolling(for: newStep)
        }
        .confirmationDialog(
            "确认移除已知旧版后台注册？",
            isPresented: $isConfirmingOrphanRecovery,
            titleVisibility: .visible
        ) {
            Button("移除已知旧版后台注册并保留数据", role: .destructive) {
                actionState = .working("正在停止并移除已确认的旧版后台注册…")
                Task {
                    if await setupCoordinator.recoverKnownLegacyOrphan() {
                        actionState = .success(
                            "旧版后台注册已移除，旧版源数据保持不变"
                        )
                    } else {
                        actionState = .failure(
                            setupCoordinator.currentError
                                ?? "旧版后台注册未能安全移除"
                        )
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只移除一个已精确识别的旧版后台注册；旧版本人模板、设置、活动记录、日志、源码和应用文件都不会删除。")
        }
        .task(id: setupCoordinator.currentStep) {
            if setupCoordinator.currentStep == .permissions {
                while !Task.isCancelled {
                    await setupCoordinator.refreshPermissions()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } else if setupCoordinator.currentStep == .safetyTest {
                while !Task.isCancelled {
                    await setupCoordinator.refreshCurrentAuthorizationStatus()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } else if setupCoordinator.currentStep == .completion {
                while !Task.isCancelled {
                    await setupCoordinator.refreshCurrentAuthorizationStatus()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private var stepSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "faceid")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(themeStore.accentColor)
                Text("Mac Face Lock")
                    .font(.system(size: 20, weight: .bold))
                Text("首次安全设置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(orderedSteps.enumerated()), id: \.element.0) { index, item in
                    HStack(spacing: 12) {
                        Image(systemName: item.2)
                            .frame(width: 22)
                        Text("\(index + 1). \(item.1)")
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(
                        setupCoordinator.currentStep == item.0
                            ? themeStore.accentColor
                            : Color.primary.opacity(0.68)
                    )
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background {
                        if setupCoordinator.currentStep == item.0 {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(themeStore.accentColor.opacity(0.14))
                        }
                    }
                }
            }
            .padding(.horizontal, 14)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("所有人脸资料和运行记录只保存在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let versionText = AppVersionDisplay.current {
                    Text(versionText)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.72))
                }
            }
            .padding(28)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch setupCoordinator.currentStep {
        case .preparation:
            preparationStep
        case .permissions:
            permissionsStep
        case .enrollment:
            enrollmentStep
        case .safetyTest:
            permissionStatusStep
        case .completion:
            completionStep
        }
    }

    private var preparationStep: some View {
        OnboardingCard(
            title: "准备检查",
            subtitle: "确认这台 Mac、应用位置和本地运行组件可以安全工作。",
            symbol: "checklist"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SetupRequirementRow(text: "Apple Silicon 与 macOS 12 或更高版本")
                SetupRequirementRow(text: "应用位于“应用程序”文件夹")
                SetupRequirementRow(text: "内置运行组件完整，无需安装其他开发工具")
                SetupRequirementRow(text: "应用支持目录可在本机安全写入")
            }

            legacyCleanupCard

            CustomerActionStatusView(state: actionState)

            Button("开始检查") {
                actionState = .working("正在检查这台 Mac…")
                Task {
                    if await setupCoordinator.prepareForSetup() {
                        actionState = .success("准备检查已通过")
                    } else {
                        actionState = .failure(
                            setupCoordinator.currentError ?? "准备检查未通过"
                        )
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking || !legacyCleanupAllowsPreparation)
        }
        .task {
            if setupCoordinator.legacyCleanupState == .unchecked {
                await setupCoordinator.inspectLegacyInstall()
            }
        }
    }

    @ViewBuilder
    private var legacyCleanupCard: some View {
        switch setupCoordinator.legacyCleanupState {
        case .unchecked:
            Label("正在检查旧版安装…", systemImage: "magnifyingglass")
        case .notRequired, .completed:
            Label(
                "未发现需要清理的旧版运行环境",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemGreen))
        case .confirmationRequired:
            legacyDestructiveConfirmation
        case .cleaning:
            Label(
                "正在处理已确认的旧版后台项目，请不要退出应用…",
                systemImage: "hourglass"
            )
        case .ambiguous(let message):
            LegacyCleanupProblemCard(
                title: "检测到的旧版结构不完整",
                message: message,
                retryTitle: "重新检查",
                secondaryActions: {
                    VStack(alignment: .leading, spacing: 8) {
                        if setupCoordinator.legacyOrphanRecoveryAvailable {
                            Button("移除已知旧版后台注册并保留数据") {
                                isConfirmingOrphanRecovery = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        HStack {
                            Button("复制诊断摘要") {
                                _ = setupCoordinator.copyLegacyDiagnostics()
                            }
                            Button("保存诊断摘要") {
                                _ = setupCoordinator.saveLegacyDiagnostics()
                            }
                            Button("打开处理指南") {
                                _ = setupCoordinator.openLegacyResolutionGuide()
                            }
                        }
                    }
                },
                retry: {
                    Task { await setupCoordinator.recheckLegacyInstall() }
                }
            )
        case .cleanupIncomplete(let message):
            LegacyCleanupProblemCard(
                title: "旧版清理尚未完成",
                message: message,
                retryTitle: "重试清理",
                secondaryActions: { EmptyView() },
                retry: {
                    Task { _ = await setupCoordinator.retryLegacyCleanup() }
                }
            )
        }
    }

    private var legacyDestructiveConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("需要清除旧版", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color(nsColor: .systemRed))
            Text("检测到旧版 Mac Face Lock。继续将停止旧版后台服务，并永久删除旧版人脸模板、配置、活动记录、证据、日志和旧应用。源码、Git 历史、文档、脚本和 Python 开发环境不会删除。此操作不可恢复。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("清理完成后，需要重新授权、录入本人并确认权限状态。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message = setupCoordinator.currentError {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            HStack {
                Button("清除旧版并继续", role: .destructive) {
                    Task { _ = await setupCoordinator.confirmLegacyCleanup() }
                }
                Button("取消", role: .cancel) {
                    setupCoordinator.cancelLegacyCleanup()
                }
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .systemRed).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var permissionsStep: some View {
        OnboardingCard(
            title: "权限中心",
            subtitle: "检查 Mac Face Lock 的三项必要权限；完成录入后会再次确认权限与后台状态。",
            symbol: "hand.raised"
        ) {
            Text("Mac Face Lock 权限")
                .font(.headline)
            VStack(spacing: 12) {
                permissionRow(.camera, title: "Mac Face Lock 摄像头", required: true)
                permissionRow(
                    .inputMonitoring,
                    title: "Mac Face Lock 输入监控",
                    required: true
                )
                permissionRow(
                    .accessibility,
                    title: "Mac Face Lock 辅助功能",
                    required: true
                )
                permissionRow(.screenRecording, title: "屏幕录制", required: false)
            }

            CustomerActionStatusView(state: actionState)

            HStack {
                backButton
                Spacer()
                Button("刷新权限") {
                    actionState = .working("正在读取系统权限…")
                    Task {
                        await setupCoordinator.refreshPermissions()
                        actionState = .success("权限状态已刷新")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)

                Button("继续录入本人") {
                    actionState = .working("正在确认 Mac Face Lock 必要权限…")
                    Task {
                        if await setupCoordinator.continueFromPermissions() {
                            actionState = .success("Mac Face Lock 必要权限已就绪")
                        } else {
                            actionState = .failure(
                                setupCoordinator.currentError ?? "必需权限尚未就绪"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || setupCoordinator.isQuitting)
            }
        }
    }

    private var enrollmentStep: some View {
        OnboardingCard(
            title: "录入本人",
            subtitle: "按照提示完成正脸与不同角度采样；取消或失败不会破坏已有资料。",
            symbol: "faceid"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("采样动作")
                    .font(.headline)
                Text("正脸 · 左转约 30° · 右转约 30° · 轻微抬头 · 轻微低头")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let pose = setupCoordinator.enrollmentPose {
                    Label(
                        "当前动作：\(enrollmentPoseLabel(pose))",
                        systemImage: "person.crop.rectangle"
                    )
                    .font(.callout.weight(.semibold))
                    EnrollmentPoseGuide(pose: pose)
                }
                if setupCoordinator.enrollmentQuality == "rejected",
                   let reason = setupCoordinator.enrollmentRejectionReason {
                    Label(
                        enrollmentRejectionLabel(reason),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                } else if setupCoordinator.enrollmentQuality == "accepted" {
                    Label("当前样本质量合格", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
            }

            if let progress = setupCoordinator.progress {
                ProgressView(value: progress) {
                    Text(progress >= 1 ? "录入完成" : "正在录入本人")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
            }

            CustomerActionStatusView(state: enrollmentActionState)

            HStack {
                backButton
                Spacer()
                if setupCoordinator.enrollmentLifecycle == .running {
                    Button("取消录入") {
                        setupCoordinator.cancelEnrollment()
                        actionState = .idle
                    }
                    .buttonStyle(.bordered)
                }
                Button(setupCoordinator.currentError == nil ? "开始录入" : "重试录入") {
                    actionState = .working("正在启动本地摄像头录入…")
                    Task {
                        await setupCoordinator.startEnrollment()
                        if setupCoordinator.currentStep == .safetyTest {
                            actionState = .success("本人人脸资料已安全保存")
                        } else if let error = setupCoordinator.currentError {
                            actionState = .failure(error)
                        } else {
                            actionState = .idle
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnrollmentWorking || setupCoordinator.isQuitting)
            }
        }
    }

    private var permissionStatusStep: some View {
        OnboardingCard(
            title: "权限确认",
            subtitle: "确认本人资料、后台服务和三项必要权限均已就绪。",
            symbol: "checkmark.shield"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                readinessRow(.ownerProfile, title: "本人人脸资料")
                readinessRow(.serviceHealth, title: "后台服务")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mac Face Lock 当前权限")
                    .font(.headline)
                agentPermissionRow(.camera, title: "Mac Face Lock 摄像头")
                agentPermissionRow(.inputMonitoring, title: "Mac Face Lock 输入监控")
                agentPermissionRow(.accessibility, title: "Mac Face Lock 辅助功能")
            }

            CustomerActionStatusView(state: actionState)

            HStack {
                backButton
                Spacer()
                Button("确认权限并继续") {
                    actionState = .working("正在刷新权限与运行状态…")
                    Task {
                        if await setupCoordinator.completePermissionStatusStep() {
                            actionState = .success("权限状态已确认")
                        } else {
                            actionState = .failure(
                                setupCoordinator.currentError
                                    ?? "必要权限或运行状态尚未就绪"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || setupCoordinator.isQuitting)
            }
        }
    }

    private var completionStep: some View {
        OnboardingCard(
            title: "完成并开启",
            subtitle: "最后确认所有门槛均已通过，再主动开启保护。",
            symbol: "checkmark.shield"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                readinessRow(.cameraPermission, title: "Mac Face Lock 摄像头")
                readinessRow(.inputMonitoringPermission, title: "Mac Face Lock 输入监控")
                readinessRow(.accessibilityPermission, title: "Mac Face Lock 辅助功能")
                readinessRow(.ownerProfile, title: "本人资料")
                readinessRow(.serviceHealth, title: "后台服务")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mac Face Lock 当前权限")
                    .font(.headline)
                agentPermissionRow(.camera, title: "Mac Face Lock 摄像头")
                agentPermissionRow(.inputMonitoring, title: "Mac Face Lock 输入监控")
                agentPermissionRow(.accessibility, title: "Mac Face Lock 辅助功能")
            }

            CustomerActionStatusView(state: actionState)

            HStack {
                backButton
                Spacer()
                Button("开启保护") {
                    actionState = .working("正在开启并确认后台保护…")
                    Task {
                        do {
                            try await setupCoordinator.enableProtection()
                            actionState = .success("保护已开启")
                        } catch {
                            actionState = .failure(
                                setupCoordinator.currentError
                                    ?? "保护未开启，请修复未通过的项目后重试"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    isWorking
                        || setupCoordinator.isQuitting
                        || !setupCoordinator.isLiveReady
                )
            }
        }
    }

    private func permissionRow(
        _ permission: SetupPermission,
        title: String,
        required: Bool
    ) -> some View {
        let state = setupCoordinator.permissionStates[permission] ?? .notDetermined
        return HStack(spacing: 14) {
            Image(systemName: permissionSymbol(for: state))
                .foregroundStyle(permissionColor(for: state))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(required ? "必需" : "可选（启用截图证据时需要）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(permissionLabel(for: state))
                .font(.callout)
                .foregroundStyle(permissionColor(for: state))
            Button(state == .denied ? "打开系统设置" : "请求授权") {
                if state == .denied {
                    setupCoordinator.openPermissionSettings(permission)
                    actionState = .success("已打开 \(title) 系统设置，返回后会自动刷新")
                } else {
                    actionState = .working("正在请求 \(title) 权限…")
                    Task {
                        await setupCoordinator.requestPermission(permission)
                        let refreshed = setupCoordinator.permissionStates[permission]
                        if refreshed == .granted || refreshed == .restartRequired {
                            actionState = .success("\(title) 权限状态已更新")
                        } else {
                            actionState = .failure(
                                "\(title) 仍未开启，请在系统设置中确认。"
                            )
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(state == .granted)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func readinessRow(_ check: SetupCheck, title: String) -> some View {
        let passed = setupCoordinator.checks[check] == true
        return Label(
            title,
            systemImage: passed ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(passed ? Color(nsColor: .systemGreen) : .secondary)
    }

    private func agentPermissionRow(
        _ permission: SetupPermission,
        title: String
    ) -> some View {
        let state = agentPermissionState(permission)
        return HStack {
            Image(systemName: state.granted ? "checkmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(
                    state.granted ? Color(nsColor: .systemGreen) : .secondary
                )
            Text(title)
            Spacer()
            Text(state.label)
                .foregroundStyle(.secondary)
            if !state.granted {
                Button("打开系统设置") {
                    setupCoordinator.openPermissionSettings(permission)
                    actionState = .success("已打开 \(title) 系统设置，返回后请重新检查")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func agentPermissionState(
        _ permission: SetupPermission
    ) -> (granted: Bool, label: String) {
        guard let status = setupCoordinator.serviceStatus,
              status.state != .notInstalled else {
            return (false, "未确认")
        }
        let granted: Bool
        switch permission {
        case .camera:
            granted = status.cameraReady
        case .inputMonitoring:
            granted = status.inputMonitoringReady
        case .accessibility:
            granted = status.accessibilityReady
        case .screenRecording:
            return (false, "此保护不需要")
        }
        return (granted, granted ? "已开启" : "未开启")
    }

    private var backButton: some View {
        Button("返回上一步") {
            setupCoordinator.goBack()
        }
        .buttonStyle(.bordered)
        .disabled(isWorking || isEnrollmentWorking)
    }

    private var isWorking: Bool {
        if case .working = actionState {
            return true
        }
        return false
    }

    private var legacyCleanupAllowsPreparation: Bool {
        switch setupCoordinator.legacyCleanupState {
        case .notRequired, .completed:
            return true
        case .unchecked, .confirmationRequired, .cleaning,
             .ambiguous, .cleanupIncomplete:
            return false
        }
    }

    private var isEnrollmentWorking: Bool {
        setupCoordinator.enrollmentLifecycle != .idle
    }

    private var enrollmentActionState: CustomerActionState {
        if setupCoordinator.enrollmentLifecycle == .cancelling {
            return .working("正在安全结束录入，请稍候…")
        }
        if let error = setupCoordinator.currentError {
            return .failure(error)
        }
        return actionState
    }

    private func updatePermissionPolling(for step: SetupStep) {
        let permissionStatusVisible = step == .permissions || step == .safetyTest
        setupCoordinator.setPermissionStepVisible(permissionStatusVisible)
        if permissionStatusVisible {
            Task {
                await setupCoordinator.refreshPermissions()
            }
        }
    }

    private func enrollmentPoseLabel(_ pose: String) -> String {
        switch pose {
        case "front": return "正脸"
        case "left": return "左转约 30°"
        case "right": return "右转约 30°"
        case "up": return "轻微抬头"
        case "down": return "轻微低头"
        default: return "按照画面提示调整"
        }
    }

    private func enrollmentRejectionLabel(_ reason: String) -> String {
        switch reason {
        case "no_face": return "未检测到脸，请正对摄像头"
        case "multiple_faces": return "画面中有多张脸，请只保留本人"
        case "too_dark": return "光线不足，请移到更明亮的位置"
        case "face_too_small": return "距离太远，请靠近摄像头"
        case "face_too_large": return "距离太近，请稍微后退"
        case "pose_mismatch": return "姿势与当前提示不符，请只重试当前动作"
        default: return "当前样本质量不足，请只重试当前动作"
        }
    }

    private func permissionLabel(for state: PermissionState) -> String {
        switch state {
        case .notDetermined:
            return "未开启"
        case .denied:
            return "未开启"
        case .restartRequired:
            return "等待重新启动"
        case .granted:
            return "已开启"
        }
    }

    private func permissionSymbol(for state: PermissionState) -> String {
        switch state {
        case .granted:
            return "checkmark.circle.fill"
        case .restartRequired:
            return "arrow.clockwise.circle.fill"
        case .notDetermined, .denied:
            return "exclamationmark.circle.fill"
        }
    }

    private func permissionColor(for state: PermissionState) -> Color {
        switch state {
        case .granted:
            return Color(nsColor: .systemGreen)
        case .restartRequired:
            return Color(nsColor: .systemOrange)
        case .notDetermined, .denied:
            return Color(nsColor: .systemRed)
        }
    }
}

private struct LegacyCleanupProblemCard: View {
    let title: String
    let message: String
    let retryTitle: String
    let secondaryActions: () -> AnyView
    let retry: () -> Void

    init<Actions: View>(
        title: String,
        message: String,
        retryTitle: String,
        @ViewBuilder secondaryActions: @escaping () -> Actions,
        retry: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.secondaryActions = { AnyView(secondaryActions()) }
        self.retry = retry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(retryTitle, action: retry)
                .buttonStyle(.bordered)
            secondaryActions()
        }
        .padding(14)
        .background(
            Color(nsColor: .systemOrange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

private struct OnboardingCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(30)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            DecorativeCardBorder(
                cornerRadius: 20,
                color: Color.white.opacity(0.12),
                lineWidth: 1
            )
        }
    }
}

private struct EnrollmentPoseGuide: View {
    let pose: String

    private var symbol: String {
        switch pose {
        case "left": return "arrow.left"
        case "right": return "arrow.right"
        case "up": return "arrow.up"
        case "down": return "arrow.down"
        default: return "viewfinder"
        }
    }

    private var title: String {
        switch pose {
        case "left": return "向左转头"
        case "right": return "向右转头"
        case "up": return "轻微抬头"
        case "down": return "轻微低头"
        default: return "保持正脸"
        }
    }

    private var instruction: String {
        switch pose {
        case "left", "right":
            return "只转动头部约 30°，身体保持不动"
        case "up":
            return "轻抬下巴约 15–20°，不要后仰身体"
        case "down":
            return "轻收下巴约 15–20°，不要弯腰或把脸完全低下去"
        default:
            return "正对摄像头，脸部保持居中"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36, weight: .medium))
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.tint)
                    .offset(x: 28, y: -28)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                Text("动作示例 · \(title)")
                    .font(.callout.weight(.semibold))
                Text(instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct SetupRequirementRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
    }
}
