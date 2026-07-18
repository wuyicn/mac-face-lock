# Security Policy

## Supported versions

Mac Face Lock 当前提供源码 Beta 与自包含桌面 Beta。安全更新目前面向 `0.1.x Beta` 源码开发线和 `0.2.x Beta` 桌面发行线；旧版本不承诺获得修复。

## 私密报告漏洞

当前尚未创建公开 GitHub 仓库，也尚未启用或实测 private vulnerability reporting，因此现在没有公开的私密报告入口，也不提供未经验证的报告邮箱。请不要在公开 Issue、讨论区或 Pull Request 中披露未修复漏洞、真实人脸模板、照片、证据、日志或其他敏感信息。

公开仓库创建并启用 private vulnerability reporting 后，仓库的 Security 页面应出现 **Report a vulnerability**。只有该入口已由维护者实测可创建私密报告时，报告者才应通过它进入 GitHub Security Advisories 流程。

这是公开发布门禁：发布前必须创建公开仓库、启用 private vulnerability reporting，并使用非维护者视角实测 **Report a vulnerability** 入口可见且可创建私密报告；验证完成后再更新本节为可用状态。项目为社区维护的 Beta，目前不承诺响应或修复时限。

## 安全边界

- 摄像头不可用或摄像头读取失败时采用 **fail-open**：保持 Mac 解锁并显示警告，避免把设备故障误判为陌生人。该行为是可用性与误锁保护策略，不是高安全策略。
- 当前人脸比对没有活体检测，照片、视频或其他重放方式可能绕过识别。
- 当前桌面发行包使用临时签名，尚未使用 Developer ID 签名或 Apple 公证。首次打开方式不等于安全背书；只从可信的 GitHub Releases 下载并核对 SHA-256。
- 项目不能替代 macOS 登录密码、Touch ID、FileVault、屏幕锁定策略、MDM 或物理访问控制。
- 默认运行时在本机处理人脸模板、状态、活动和证据。外部通知默认关闭；启用自定义通知脚本后，数据会离开本机的范围取决于该脚本和接收系统。

Mac Face Lock 不适用于高安全环境、合规门禁、身份认证、无人值守的敏感终端，或任何需要防伪造、活体证明和强制拒绝访问的场景。
