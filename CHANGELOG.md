# Changelog

本项目的所有重要变更都记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)。Beta 标签使用 Git tag `v0.1.0-beta`，应用内营销版本为 `0.1.0`、build 为 `1`。

## [Unreleased]

## [0.1.0-beta] - 2026-07-15

### Added

- 可从任意主仓库路径运行的便携安装、卸载和 LaunchAgent 渲染流程。
- 菜单栏与桌面控制中心组成的统一界面，提供保护、记录和设置页面。
- 本地人脸录入、短时验证、活动时间线和可选锁屏证据。
- 默认关闭的外部通知接口，可由用户显式配置本地通知脚本。

### Changed

- 摄像头不可用时使用 fail-open 策略，保持 Mac 解锁并显示警告。
- 人脸模板、状态、活动、界面偏好和证据作为本地数据保存；卸载服务时予以保留。
- Python 依赖通过 `requirements-lock.txt` 固定版本安装。

### Security

- 明确当前版本没有活体检测，不能替代 macOS 系统安全能力，也不适用于高安全场景。
- 首个公开版本为仅源码 Beta，不提供签名或公证的二进制发行包。
