# 会话交接记录

更新时间：2026-05-07

## 项目目标

在 macOS 上运行一个本地 Agent，用于防止非本人使用电脑：

- 本人正常使用时不频繁打扰。
- 本人离开后进入保护态，但不立即锁屏。
- 保护态下有人操作鼠标或键盘时，做人脸验证。
- 验证为本人则放行。
- 非本人、无人脸或无法确认本人时，保存一次屏幕截图并锁屏。
- 锁屏后保持系统、网络和 Agent 在线。

## 当前策略

当前采用 `presence_guard` 模式：

```text
正常使用电脑
        ↓
短时间输入只更新时间，不检查摄像头
        ↓
连续 60 秒无输入
        ↓
进入保护态 armed，但不锁屏
        ↓
保护态下有人输入
        ↓
摄像头验证本人
        ↓
本人：放行并退出保护态
非本人 / 无人脸 / 无法确认：截图并锁屏
```

## 当前运行状态

已完成：

- 项目目录：`/path/to/mac-face-lock-agent`
- 本人脸部特征：`data/owner_face.npy`
- 默认配置：`config/config.json`
- 前台测试入口：`scripts/run-agent-terminal.command`
- 状态检查入口：`scripts/status.sh`
- 锁屏前截图保存：`data/evidence/`

当前测试方式：

- 已安装 LaunchAgent 后台常驻。
- 换电脑后已修复旧用户路径。
- 当前需要确认新电脑上的辅助功能、输入监控和摄像头权限。

## 已验证事实

- 摄像头权限已通过 Terminal 授权。
- 输入监控和辅助功能权限已通过 Terminal 授权。
- 本人脸部特征已录入成功。
- `presence_guard` 已经能进入保护态。
- 保护态下 `no_face` 能触发锁屏链路。
- 锁屏前截图保存已成功生成过证据文件。

## 一天测试计划

从 2026-05-07 开始先跑一天。

次日复盘内容：

- `logs/agent.log`
- `data/state.json`
- `data/evidence/`

需要统计：

- 进入保护态次数。
- 验证本人次数。
- `no_face` / `stranger` / `unknown` 次数。
- 锁屏次数。
- 截图保存次数。
- 锁屏命令失败次数。
- 是否存在误锁或漏锁。

## 后续优化方向

- 根据一天日志调整 `idle_seconds_before_armed`。
- 根据误识别情况调整 `face_match_threshold`。
- 确认稳定后再安装 LaunchAgent 后台运行。
- 如果后台权限不稳定，再考虑封装成 macOS App 或菜单栏 App。
