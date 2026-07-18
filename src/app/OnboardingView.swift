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

    private let orderedSteps: [(SetupStep, String, String)] = [
        (.preparation, "准备检查", "checklist"),
        (.permissions, "权限中心", "hand.raised"),
        (.enrollment, "录入本人", "faceid"),
        (.safetyTest, "安全测试", "shield.checkered"),
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
        .onReceive(setupCoordinator.$currentStep.removeDuplicates()) { newStep in
            actionState = .idle
            updatePermissionPolling(for: newStep)
        }
        .task(id: setupCoordinator.currentStep) {
            if setupCoordinator.currentStep == .permissions {
                while !Task.isCancelled {
                    await setupCoordinator.refreshPermissions()
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

            Text("所有人脸资料和运行记录只保存在本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            safetyTestStep
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
                "正在停止并清除旧版，请不要退出应用…",
                systemImage: "hourglass"
            )
        case .ambiguous(let message):
            LegacyCleanupProblemCard(
                title: "检测到的旧版结构不完整",
                message: message,
                retryTitle: "重新检查",
                retry: {
                    Task { await setupCoordinator.recheckLegacyInstall() }
                }
            )
        case .cleanupIncomplete(let message):
            LegacyCleanupProblemCard(
                title: "旧版清理尚未完成",
                message: message,
                retryTitle: "重试清理",
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
            Text("清理完成后，需要重新授权、录入本人并完成安全测试。")
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
            subtitle: "这里先检查 Mac Face Lock 控制中心；后台 Agent 的独立权限会在安全测试中确认。",
            symbol: "hand.raised"
        ) {
            Text("Mac Face Lock 控制中心权限")
                .font(.headline)
            VStack(spacing: 12) {
                permissionRow(.camera, title: "摄像头", required: true)
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
                    actionState = .working("正在确认控制中心摄像头权限…")
                    Task {
                        if await setupCoordinator.continueFromPermissions() {
                            actionState = .success("控制中心摄像头权限已就绪")
                        } else {
                            actionState = .failure(
                                setupCoordinator.currentError ?? "必需权限尚未就绪"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
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
                Text("正脸 · 左转约 30° · 右转约 30° · 轻微低头 · 轻微抬头")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .disabled(isEnrollmentWorking)
            }
        }
    }

    private var safetyTestStep: some View {
        OnboardingCard(
            title: "安全测试",
            subtitle: "验证后台服务、摄像头、本人资料与实际权限；测试不会触发锁屏。",
            symbol: "shield.checkered"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                readinessRow(.diagnosis, title: "运行组件与数据目录")
                readinessRow(.ownerProfile, title: "本人人脸资料")
                readinessRow(.ownerTest, title: "本人验证（不锁屏）")
                readinessRow(.serviceHealth, title: "后台服务与实际权限")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mac Face Lock Agent 权限")
                    .font(.headline)
                agentPermissionRow(.camera, title: "Agent 摄像头")
                agentPermissionRow(.inputMonitoring, title: "Agent 输入监控")
                agentPermissionRow(.accessibility, title: "Agent 辅助功能")
            }

            CustomerActionStatusView(state: actionState)

            HStack {
                backButton
                Spacer()
                Button("运行安全测试") {
                    actionState = .working("正在执行不锁屏安全测试…")
                    Task {
                        if await setupCoordinator.runSafetyTest() {
                            actionState = .success("所有安全测试已通过")
                        } else {
                            actionState = .failure(
                                setupCoordinator.currentError ?? "安全测试未全部通过"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
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
                readinessRow(.cameraPermission, title: "控制中心摄像头权限")
                readinessRow(.inputMonitoringPermission, title: "Agent 输入监控权限")
                readinessRow(.accessibilityPermission, title: "Agent 辅助功能权限")
                readinessRow(.ownerProfile, title: "本人资料")
                readinessRow(.ownerTest, title: "本人安全测试")
                readinessRow(.serviceHealth, title: "后台服务")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Mac Face Lock Agent 当前权限")
                    .font(.headline)
                agentPermissionRow(.camera, title: "Agent 摄像头")
                agentPermissionRow(.inputMonitoring, title: "Agent 输入监控")
                agentPermissionRow(.accessibility, title: "Agent 辅助功能")
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
                .disabled(isWorking || !setupCoordinator.isLiveReady)
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
            return (false, "不由 Agent 使用")
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
        setupCoordinator.setPermissionStepVisible(step == .permissions)
        if step == .permissions {
            Task {
                await setupCoordinator.refreshPermissions()
            }
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
    let retry: () -> Void

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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SetupRequirementRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
    }
}
