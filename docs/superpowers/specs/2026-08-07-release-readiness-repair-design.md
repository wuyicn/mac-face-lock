# Mac Face Lock 发布准备度修复设计

日期：2026-08-07

## 目标

在不发布、不合并、不修改 macOS 隐私权限和不清理用户现有文件的前提下，修复当前已证实的本地发布阻塞：Linux CI 误跑 macOS 图标测试、公开文档与 GitHub 实际状态不一致、发行包缺少源提交追溯，以及分支差异中的尾随空格。

## 已选方案

采用“本地发布准备度收口”方案，而不是仅修 CI，也不直接执行远端发布。该方案让本地实现形成一组可审查、可测试、可推送的提交；GitHub 分支保护、推送、合并、Release 创建和系统权限确认仍是后续独立门禁。

## 修复范围

### 1. Linux CI 平台隔离

- 保留完整 Python 测试在 Linux 和 macOS 两个作业中运行。
- 将依赖 `iconutil`、`xcrun` 和 Swift 图标生成器的两个测试显式标记为仅在 macOS 图标工具链可用时运行。
- 添加回归测试，在模拟 `sys.platform == "linux"` 的全新解释器中导入测试模块，并证明这两个测试会被标记为 skip。
- 不通过删除测试或放宽图标内容断言来换取 CI 通过。

### 2. GitHub 与安全文档事实一致

- `SECURITY.md` 改为说明仓库已经公开并已启用 GitHub private vulnerability reporting，指向仓库 Security Advisories 的私密报告入口。
- `README.md` 不再暗示当前一定存在可下载 Release；改为永久有效的规则：只认官方 Releases 页面，如果页面没有发行版，就表示尚未公开客户构建。
- 更新现有公开文档策略测试，防止以后重新出现“仓库未公开/私密报告未启用”或“无 Release 仍声称可下载”的矛盾。

### 3. 提交到发行包的可追溯链

- `scripts/build-release.sh` 在构建前要求 Git 工作区的跟踪内容干净，并读取完整 40 位 `HEAD` SHA。
- `scripts/release-manifest.py` 生成 schema v3 清单，新增严格格式的 `source_commit` 字段；校验器拒绝缺失、非 40 位小写十六进制或被篡改的提交值。
- 人工验收脚本输出发行包内记录的源提交 SHA，使验收记录能够形成 `commit SHA -> manifest -> ZIP SHA-256 -> GitHub Release` 链。
- 旧 schema v2 产物不再满足新发布门禁；现有安装应用不被修改，但必须使用修复后的干净提交重新构建才可发布。

### 4. 低风险仓库卫生

- 清理 `origin/main...HEAD` 中已发现的文档尾随空格，使差异检查通过。
- 不修改主 checkout 中的 `node_modules/`、验收报告、`package.json`、名为 `-` 的文件或任何其他未跟踪内容。
- 暂不改写 macOS 14 弃用的 `onChange` 调用，因为替换 API 的系统版本边界需要单独兼容性设计，且它不是当前发布阻塞。

## 数据流与失败策略

发布构建从干净 Git `HEAD` 读取 SHA，构建应用后把 SHA 写入最终 Bundle 的 `BuildManifest.json`，再签名并打包 ZIP。清单校验、ZIP 校验和人工验收任何一步发现 SHA 缺失或格式错误都失败关闭。构建脚本不会自动提交、推送、创建 Release 或启动应用。

## 验证标准

- 新增 Linux 平台隔离回归测试先失败、修复后通过。
- 清单 schema v3 的生成、缺失字段、非法 SHA、篡改 SHA 和正确 SHA 均有自动测试。
- 完整 Python 测试通过；Linux 模拟导入证明 macOS 图标测试会 skip。
- 15 个 Swift 测试套件和完整 Swift typecheck 通过。
- Shell、plist、`git diff --check origin/main...HEAD` 和依赖漏洞审计通过。
- 在修复提交形成后，从干净提交重新构建 ZIP；签名、manifest、Bundle ID、统一 TCC identity、ZIP SHA-256 和解压验证通过。
- 最终报告仍把实时 TCC 权限、GitHub 推送/CI、分支保护、合并和 Release 标记为未自动完成，除非另有新鲜证据。

## 非目标

- 不清理主 checkout 或用户文件。
- 不自动授予摄像头、输入监控、辅助功能或屏幕录制权限。
- 不自动开启保护、重启服务或替换当前安装应用。
- 不推送分支、不修改 GitHub 分支保护、不合并 PR、不创建 Release。
- 不在本轮引入 Developer ID 签名、公证、活体检测或跨架构发行。
