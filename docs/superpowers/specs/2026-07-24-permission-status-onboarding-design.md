# Permission Status Onboarding Design

## Goal

让用户在录入本人后，通过三项系统权限状态确认直接完成 onboarding；取消“运行安全测试”作为用户可见的必经卡点。

## Design

- 保留 `SetupStep.safetyTest` 和历史 `safety_test` 存储值，避免破坏已有记录；UI 将其显示为“权限确认”。
- 权限确认页只显示摄像头、输入监控、辅助功能的实时状态，并提供刷新/打开系统设置动作；不再提供“运行安全测试”按钮。
- 完成条件为：本人模板有效、摄像头/输入监控/辅助功能已授权、后台服务健康。`diagnosis` 与 `ownerTest` 保留为诊断信息，但不再阻塞完成或开启保护。
- `enableProtection()` 继续在写入保护开关前刷新权限、服务和本人资料；任何必需状态失效都写回关闭并拒绝开启。
- 历史已完成用户继续兼容；权限撤销时回到权限恢复界面，不要求重新运行安全测试。

## Scope

- 修改 `SetupReadiness` 的 required checks。
- 增加 `SetupCoordinator.completePermissionStatusStep()`，只刷新状态并持久化 completion。
- 更新 `OnboardingView`、`SettingsView` 和相关中文文案。
- 增加 Swift 回归测试，覆盖权限状态足够完成、缺权限仍拒绝、撤销权限回退。

## Non-goals

- 不修改 TCC 权限、不自动点击系统设置。
- 不改变单一 App 身份、LaunchAgent、后台 runtime 或保护 fail-open 语义。
