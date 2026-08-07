import SwiftUI

struct SettingsView: View {
    @ObservedObject var setupCoordinator: SetupCoordinator
    @ObservedObject var faceLockStore: FaceLockStore
    @ObservedObject var themeStore: ThemeStore

    @State private var permissionAction: CustomerActionState = .idle
    @State private var enrollmentAction: CustomerActionState = .idle
    @State private var protectionAction: CustomerActionState = .idle
    @State private var serviceAction: CustomerActionState = .idle
    @State private var isConfirmingServiceUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置")
                    .font(.system(size: 30, weight: .bold))

                if !setupCoordinator.isLiveReady {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            recoveryMessage,
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(Color(nsColor: .systemOrange))

                        if setupCoordinator.recoveryStep == .safetyTest {
                            Button("刷新权限与运行状态") {
                                protectionAction = .working("正在刷新权限与运行状态…")
                                Task {
                                    await setupCoordinator.refreshLiveReadiness()
                                    if setupCoordinator.isLiveReady {
                                        protectionAction = .success("权限与运行状态已刷新")
                                    } else {
                                        protectionAction = .failure(
                                            setupCoordinator.currentError
                                                ?? "必要权限或后台服务尚未就绪"
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                isWorking(protectionAction)
                                    || setupCoordinator.isQuitting
                            )
                        }
                    }
                    .padding(16)
                    .background(
                        Color(nsColor: .systemOrange).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }

                permissionsSection
                ownerSection
                protectionSection
                serviceSection
                appearanceSection
            }
            .padding(.horizontal, 42)
            .padding(.top, 54)
            .padding(.bottom, 42)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            await setupCoordinator.refreshLiveReadiness()
        }
        .confirmationDialog(
            "确认卸载后台服务？",
            isPresented: $isConfirmingServiceUninstall,
            titleVisibility: .visible
        ) {
            Button("卸载后台服务并保留数据", role: .destructive) {
                serviceAction = .working("正在停止并卸载后台服务…")
                Task {
                    if await setupCoordinator.uninstallServicePreservingData() {
                        serviceAction = .success(
                            "后台服务已卸载；本人模板、设置和活动记录仍保留在本机"
                        )
                    } else {
                        serviceAction = .failure(
                            setupCoordinator.currentError ?? "后台服务卸载未完成"
                        )
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保护将停止，应用数据会保留，之后可通过“修复后台保护”继续使用。")
        }
    }

    private var permissionsSection: some View {
        SettingsSection(title: "权限与运行状态", symbol: "hand.raised.fill") {
            Text("Mac Face Lock 权限")
                .font(.headline)
            VStack(spacing: 11) {
                settingsPermissionRow(.camera, title: "Mac Face Lock 摄像头")
                settingsPermissionRow(
                    .inputMonitoring,
                    title: "Mac Face Lock 输入监控"
                )
                settingsPermissionRow(
                    .accessibility,
                    title: "Mac Face Lock 辅助功能"
                )
                settingsPermissionRow(.screenRecording, title: "屏幕录制（可选）")
            }

            CustomerActionStatusView(state: permissionAction)

            Button("刷新权限") {
                permissionAction = .working("正在读取系统权限…")
                Task {
                    await setupCoordinator.refreshPermissions()
                    permissionAction = .success("权限状态已刷新")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking(permissionAction))

        }
    }

    private var ownerSection: some View {
        SettingsSection(title: "本人资料", symbol: "person.crop.circle") {
            StatusLine(
                title: "本人人脸模板",
                detail: setupCoordinator.checks[.ownerProfile] == true
                    ? "已在本机安全保存"
                    : "尚未找到有效资料",
                healthy: setupCoordinator.checks[.ownerProfile] == true
            )

            if let progress = setupCoordinator.progress, progress < 1 {
                ProgressView(value: progress) {
                    Text("正在重新录入本人")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
            }

            CustomerActionStatusView(state: enrollmentStatus)

            HStack {
                Button("重新录入本人") {
                    enrollmentAction = .working("正在启动本地摄像头录入…")
                    Task {
                        await setupCoordinator.startEnrollment()
                        if setupCoordinator.currentStep == .safetyTest {
                            enrollmentAction = .success("新资料已保存，请确认权限状态")
                        } else {
                            enrollmentAction = .failure(
                                setupCoordinator.currentError ?? "重新录入未完成"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnrollmentWorking || setupCoordinator.isQuitting)

                if setupCoordinator.enrollmentLifecycle == .running {
                    Button("取消录入") {
                        setupCoordinator.cancelEnrollment()
                        enrollmentAction = .idle
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var protectionSection: some View {
        SettingsSection(title: "保护规则", symbol: "shield.lefthalf.filled") {
            StatusLine(
                title: "当前保护",
                detail: faceLockStore.protectionEnabled ? "已开启" : "已暂停",
                healthy: faceLockStore.protectionEnabled
            )

            Text("摄像头不可用时保持解锁并显示警告；关闭截图证据时不要求屏幕录制权限。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CustomerActionStatusView(state: protectionAction)

            Button(faceLockStore.protectionEnabled ? "暂停保护" : "恢复保护") {
                protectionAction = .working(
                    faceLockStore.protectionEnabled ? "正在暂停保护…" : "正在确认安全门槛…"
                )
                Task {
                    if faceLockStore.protectionEnabled {
                        faceLockStore.setProtectionEnabled(false)
                        protectionAction = faceLockStore.lastError == nil
                            ? .success("保护已暂停")
                            : .failure(faceLockStore.lastError ?? "无法暂停保护")
                    } else {
                        do {
                            try await setupCoordinator.enableProtection()
                            faceLockStore.refresh()
                            protectionAction = .success("保护已恢复")
                        } catch {
                            protectionAction = .failure(
                                setupCoordinator.currentError ?? "安全门槛尚未就绪"
                            )
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isWorking(protectionAction)
                    || setupCoordinator.isQuitting
            )
        }
    }

    private var serviceSection: some View {
        SettingsSection(title: "服务诊断与修复", symbol: "wrench.and.screwdriver.fill") {
            StatusLine(
                title: "后台服务",
                detail: serviceDetail,
                healthy: setupCoordinator.checks[.serviceHealth] == true
            )

            VStack(spacing: 9) {
                agentPermissionRow(.camera, title: "Mac Face Lock 摄像头")
                agentPermissionRow(.inputMonitoring, title: "Mac Face Lock 输入监控")
                agentPermissionRow(.accessibility, title: "Mac Face Lock 辅助功能")
            }

            CustomerActionStatusView(state: serviceStatus)

            HStack {
                Button("重新启动服务") {
                    serviceAction = .working("正在重新启动后台服务…")
                    Task {
                        await setupCoordinator.restartService()
                        updateServiceAction(successMessage: "后台服务已重新启动")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isWorking(serviceAction)
                        || setupCoordinator.isQuitting
                )

                Button("修复后台保护") {
                    serviceAction = .working("正在修复后台保护…")
                    Task {
                        await setupCoordinator.reinstallService()
                        updateServiceAction(successMessage: "后台保护已修复")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    isWorking(serviceAction)
                        || setupCoordinator.isQuitting
                )

                Button("查看日志") {
                    if setupCoordinator.openLogs() {
                        serviceAction = .success("已打开本地日志文件夹")
                    } else {
                        serviceAction = .failure(
                            setupCoordinator.currentError ?? "无法打开日志文件夹"
                        )
                    }
                }
                .buttonStyle(.bordered)
            }

            Button("卸载后台服务并保留数据") {
                isConfirmingServiceUninstall = true
            }
            .buttonStyle(.bordered)
            .disabled(
                isWorking(serviceAction)
                    || setupCoordinator.isQuitting
            )
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "外观", symbol: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Text("显示模式")
                    .font(.headline)
                Picker("显示模式", selection: appearanceBinding) {
                    Text("跟随系统").tag(AppearanceMode.system)
                    Text("浅色").tag(AppearanceMode.light)
                    Text("深色").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("主题颜色")
                    .font(.headline)
                HStack(spacing: 14) {
                    AccentChoiceCard(
                        title: "深海蓝",
                        theme: .oceanBlue,
                        color: settingsAccentColor(for: .oceanBlue),
                        selectedTheme: themeStore.preferences.accent,
                        onSelect: themeStore.setAccent
                    )
                    AccentChoiceCard(
                        title: "守护绿",
                        theme: .guardianGreen,
                        color: settingsAccentColor(for: .guardianGreen),
                        selectedTheme: themeStore.preferences.accent,
                        onSelect: themeStore.setAccent
                    )
                    AccentChoiceCard(
                        title: "紫晶",
                        theme: .amethyst,
                        color: settingsAccentColor(for: .amethyst),
                        selectedTheme: themeStore.preferences.accent,
                        onSelect: themeStore.setAccent
                    )
                }
            }
        }
    }

    private func settingsPermissionRow(
        _ permission: SetupPermission,
        title: String
    ) -> some View {
        let state = setupCoordinator.permissionStates[permission] ?? .notDetermined
        return HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(state == .granted ? Color(nsColor: .systemGreen) : .secondary)
                .frame(width: 22)
            Text(title)
            Spacer()
            Text(permissionLabel(state))
                .foregroundStyle(.secondary)
            Button(state == .denied ? "打开系统设置" : "请求授权") {
                if state == .denied {
                    setupCoordinator.openPermissionSettings(permission)
                    permissionAction = .success(
                        "已打开 \(title) 系统设置，返回后会自动刷新"
                    )
                } else {
                    permissionAction = .working("正在请求 \(title) 权限…")
                    Task {
                        await setupCoordinator.requestPermission(permission)
                        let refreshed = setupCoordinator.permissionStates[permission]
                        if refreshed == .granted || refreshed == .restartRequired {
                            permissionAction = .success("\(title) 权限状态已更新")
                        } else {
                            permissionAction = .failure(
                                "\(title) 仍未开启，请在系统设置中确认。"
                            )
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(state == .granted)
        }
        .padding(.vertical, 3)
    }

    private var enrollmentStatus: CustomerActionState {
        if let error = setupCoordinator.currentError,
           isWorking(enrollmentAction) || enrollmentAction == .idle {
            return .failure(error)
        }
        return enrollmentAction
    }

    private var serviceStatus: CustomerActionState {
        if let error = setupCoordinator.currentError, isWorking(serviceAction) {
            return .failure(error)
        }
        return serviceAction
    }

    private var serviceDetail: String {
        guard let status = setupCoordinator.serviceStatus else {
            return "尚未读取运行状态"
        }
        switch status.state {
        case .healthy:
            if let heartbeat = status.heartbeatTimestamp {
                return "运行正常 · 最近心跳 \(heartbeat)"
            }
            return "运行正常"
        case .notInstalled:
            return "尚未安装"
        case .unhealthy:
            return "运行异常，需要诊断"
        case .needsRepair:
            return "应用位置已变化，需要修复后台保护"
        }
    }

    private var recoveryMessage: String {
        switch setupCoordinator.recoveryStep {
        case .permissions:
            return "首次设置记录仍然保留。请恢复 Mac Face Lock 摄像头权限，随后重新确认本人。"
        case .enrollment:
            return "首次设置记录仍然保留，但当前本人模板无效，请重新录入本人。"
        case .safetyTest:
            return "首次设置记录仍然保留。请确认三项必要权限和后台服务状态。"
        case .completion:
            return "首次设置记录仍然保留。后台服务需要诊断或修复。"
        case .preparation, .none:
            return "首次设置已完成，但当前安全状态尚未全部确认。恢复保护前会重新验证全部门槛。"
        }
    }

    private var isEnrollmentWorking: Bool {
        setupCoordinator.enrollmentLifecycle != .idle
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
                .frame(width: 22)
            Text(title)
            Spacer()
            Text(state.label)
                .foregroundStyle(.secondary)
            if !state.granted {
                Button("打开系统设置") {
                    setupCoordinator.openPermissionSettings(permission)
                    let message = CustomerActionState.success(
                        "已打开 Mac Face Lock 的 \(title) 设置页，返回后请刷新状态"
                    )
                    permissionAction = message
                    serviceAction = message
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 3)
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

    private func updateServiceAction(successMessage: String) {
        if setupCoordinator.checks[.serviceHealth] == true {
            serviceAction = .success(successMessage)
        } else {
            serviceAction = .failure(
                setupCoordinator.currentError ?? "后台服务仍未恢复正常"
            )
        }
    }

    private func isWorking(_ state: CustomerActionState) -> Bool {
        if case .working = state {
            return true
        }
        return false
    }

    private func permissionLabel(_ state: PermissionState) -> String {
        switch state {
        case .notDetermined, .denied:
            return "未开启"
        case .restartRequired:
            return "等待重新启动"
        case .granted:
            return "已开启"
        }
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { themeStore.preferences.appearance },
            set: { themeStore.setAppearance($0) }
        )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol)
                .font(.system(size: 20, weight: .semibold))
            content
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            DecorativeCardBorder(
                cornerRadius: 18,
                color: Color.white.opacity(0.10),
                lineWidth: 1
            )
        }
    }
}

private struct StatusLine: View {
    let title: String
    let detail: String
    let healthy: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(
                    healthy
                        ? Color(nsColor: .systemGreen)
                        : Color(nsColor: .systemOrange)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct AccentChoiceCard: View {
    let title: String
    let theme: AccentTheme
    let color: Color
    let selectedTheme: AccentTheme
    let onSelect: (AccentTheme) -> Void

    var body: some View {
        Button {
            onSelect(theme)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle()
                        .fill(color)
                        .frame(width: 42, height: 42)
                    Spacer()
                    if theme == selectedTheme {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(color)
                    }
                }
                Text(title)
                    .font(.headline)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        theme == selectedTheme ? color : Color.primary.opacity(0.10),
                        lineWidth: theme == selectedTheme ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private func settingsAccentColor(for theme: AccentTheme) -> Color {
    switch theme {
    case .oceanBlue:
        return Color(red: 0.20, green: 0.48, blue: 0.96)
    case .guardianGreen:
        return Color(red: 0.28, green: 0.67, blue: 0.32)
    case .amethyst:
        return Color(red: 0.56, green: 0.32, blue: 0.86)
    }
}
