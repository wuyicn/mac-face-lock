# Mac Face Lock 0.2.0-beta 发行交接

更新时间：2026-07-19（Asia/Shanghai）

## 结论

源码、自动化测试和本地生成的离线发行包已通过本轮自动门禁。当前唯一未完成的产品验收是：在一个全新的普通 macOS 测试账户中，使用真实系统权限和摄像头走完整安装流程。

本记录不代表已完成该人工验收，也不授权自动创建账户、修改 TCC 权限、发布 GitHub Release 或推送仓库。

## 已验证版本

- 已验证实现提交：`b004ac2ee4ee29901c11d07d3c8423ec2fd71b67`
- 分支：`codex/self-contained-onboarding`
- 应用营销版本：`0.2.0`
- build：`1`
- 发行标识：`0.2.0-beta`
- 构建主机：Apple Silicon，macOS `26.5.1`（build `25F80`）
- 冻结运行时：CPython `3.11.15`
- 打包工具：PyInstaller `6.21.0`
- uv：`0.11.13`

## 最终发行构件

- ZIP：`dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip`
- 大小：`63,391,865` bytes
- SHA-256：`8aecfd9115d424367627376c9da74cd37aaf052c80a7bedabbde4064bd4f0070`
- 校验文件：`dist/release/Mac-Face-Lock-0.2.0-beta-arm64.zip.sha256`

ZIP 与校验文件已用 `shasum -a 256 -c` 核对通过。解压后的外层应用、内嵌 Agent 和冻结运行时均为 arm64，最低系统版本为 macOS `12.0`；外层应用和内嵌代码的临时签名已通过严格深度验证。

`BuildManifest.json` 使用 schema `2`、范围 `final_non_code_payload`。最终清单覆盖 `45` 个非代码文件；另有 `109` 个仅因清单自身、代码签名或 Mach-O 代码而明确排除的文件。清单逐文件摘要验证通过，且覆盖默认配置、处理指南、LaunchAgent 模板、Python 基础库、OpenCV 人脸级联、MIT 许可证、第三方声明及以下 7 组实际许可证文件：

- Python
- NumPy
- opencv-python
- opencv-python 第三方声明
- pynput
- six
- PyObjC

## 自动化验证证据

- Python：`217` 个测试通过，`1` 个按设计跳过。跳过项只是在源码阶段要求发行构件的套件；同一套件随后针对最终 ZIP 单独执行。
- Python 源码编译检查：通过。
- 所有 `scripts/*.sh` 与 `scripts/*.command` 语法检查：通过。
- Swift：11 个可执行套件全部编译并通过：
  - LocalStore
  - SetupState
  - PermissionState
  - RuntimeCommandRunner
  - ServiceManager
  - SetupCoordinator
  - ProjectLocator
  - AppEnvironment
  - AgentLauncherPath
  - SecureFileTree
  - LegacyInstallCleaner
- 统一 Swift 应用类型检查：通过。
- 源码构建的 Agent 与控制中心：plist、严格深度签名、arm64、macOS 12.0 门禁通过。
- 最终解压发行包：5 项有效测试通过，1 项校验测试按设计跳过；ZIP 校验已由构建脚本独立通过。
- 解压发行包不包含当前开发目录、用户主目录、`.venv`、系统 Python 或 Homebrew Python 路径。
- 解压应用在测试启动窗口内可运行，且无需源码仓库或开发工具。
- `scripts/manual-release-acceptance.sh` 自动预检：通过。
- `git diff --check`：通过。

## 本轮补齐的用户能力

- 普通客户从 GitHub Releases 下载 ZIP 后，不需要 Codex、Python、Xcode、终端或源码仓库。
- 首次设置提供准备检查、权限中心、五姿态本人录入、权限确认和明确开启保护。
- 设置页提供“卸载后台服务并保留数据”，要求二次确认；成功后停止服务并保留本人模板、设置与活动记录。
- 旧版结构只有在两个完整已知注册属于同一源码目录时，才会显示不可恢复的完整清理确认。
- 单个落单注册只有在精确匹配已知 Agent 或状态服务格式、身份稳定且属于当前用户时，才会显示“移除已知旧版后台注册并保留数据”。
- 未知格式、混合新旧结构或操作期间被替换的注册继续保持阻塞，不会被自动删除。
- 删除流程在删除开始前把每个精确 purge 路径、身份、类型和普通文件版本持久化到受限清理日志。即使在最终重命名和父目录同步后中断，新进程也只恢复日志中的精确路径；不匹配的替换对象会保留并使清理失败关闭。
- 完成标记写入前会审计固定六个原目标、全部 tombstone 根和日志中的全部 purge 路径；不会通过扫描隐藏名称猜测遗留文件。
- 最终按路径删除仍明确保留同一用户攻击者可观察并竞争随机路径的系统限制，不宣称绝对消除。

## 全新账户人工验收：PENDING

执行人应先运行：

```bash
scripts/manual-release-acceptance.sh
```

该脚本只校验现有构件并打印清单，不创建账户、不修改隐私权限、不启动应用。随后在新建的普通测试账户中逐项填写 PASS / FAIL：

- [ ] 账户未安装 Codex、Python、Xcode，且没有源码仓库。
- [ ] 只用 Finder 解压、拖入“应用程序”，并用右键“打开”首次启动。
- [ ] 摄像头授权、拒绝和返回后的状态刷新正确。
- [ ] 五姿态录入完成；取消或失败不保存不完整模板。
- [ ] Mac Face Lock 应用的摄像头、输入监控和辅助功能权限可通过界面完成。
- [ ] 权限确认实时显示统一 Mac Face Lock 应用身份的必要权限和后台服务状态，所有门槛通过前不能开启保护。
- [ ] 开启保护后重新登录，后台服务自动恢复且状态正确。
- [ ] 撤销并恢复一项必需权限后，应用进入安全恢复状态并可修复。
- [ ] “重新安装服务”保留本人模板和设置。
- [ ] “卸载后台服务并保留数据”停止服务并保留数据，然后才能把应用移到废纸篓。
- [ ] 旧源码数据未在未确认范围内被读取、更改或删除。

## 发布门禁

以下事项完成前，不应对外宣称 0.2.0-beta 已通过普通客户验收：

1. 上述全新账户清单全部 PASS，并记录 macOS 版本与简短证据。
2. 公共 GitHub 仓库已创建，private vulnerability reporting 已启用，并从非维护者视角实测入口。
3. 手动 GitHub Actions 构件工作流已在远端运行并核对输出。
4. 最终要上传的 ZIP SHA-256 与本记录一致；若重新构建，必须更新校验值并重新验收。

当前发行包使用临时签名且未公证，首次启动仍需 Finder 右键打开。产品没有活体检测，摄像头故障保持 fail-open，不能替代 macOS 密码、Touch ID、FileVault 或高安全身份认证。
