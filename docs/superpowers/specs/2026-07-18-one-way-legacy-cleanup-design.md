# Mac Face Lock 一次性旧版清理与发行版接管设计

**日期：** 2026-07-18
**状态：** 已确认
**适用分支：** `codex/self-contained-onboarding`

## 1. 决策

Mac Face Lock 首个开源 Beta 将源码测试版和发行版视为同一产品的前后两个阶段，不并行保留旧运行环境。

发行版首次启动时，如果确认当前用户仍安装着本项目已知的源码测试版，必须先让用户明确确认一次不可恢复的清理操作。确认后，发行版停止并删除源码测试版的两个后台服务，永久删除源码版的配置、人脸模板、活动记录、证据、日志和已构建应用，然后从全新的权限检查、本人录入和安全测试开始。

不备份、不导入、不恢复旧数据。源码文件、Git 历史、文档、脚本和 Python 开发环境保留。

此设计取代 `2026-07-18-defer-source-beta-migration-design.md` 中“旧源码安装及其数据保持原样”和“不读取旧 LaunchAgent”的边界。自动导入仍然暂缓；本设计只增加经过确认的旧版识别、删除和服务接管。

## 2. 目标与非目标

### 2.1 目标

- 解决源码版与发行版共用 `com.wuyi.mac-face-lock-agent` 导致的服务冲突。
- 让普通用户无需 Codex、终端或手工清理即可完成从源码测试版到发行版的单向切换。
- 删除源码测试版产生的全部已知本地运行数据，同时保留开发资产。
- 任何身份、路径或文件类型存在歧义时停止清理，避免误删其他项目或用户文件。
- 清理失败时保持保护功能关闭，并提供可安全重试的明确状态。

### 2.2 非目标

- 不迁移或转换旧配置、人脸模板、活动记录、界面偏好或证据。
- 不提供备份、撤销、恢复源码版服务或降级入口。
- 不删除当前发行版的 `~/Library/Application Support/Mac Face Lock` 数据。
- 不删除源码根目录、源码文件、`.git`、`.worktrees`、`.venv`、文档或脚本。
- 不识别任意第三方或未知历史安装结构。
- 不恢复已撤出的逐文件自动迁移实现。

## 3. 启用边界

旧版清理器只在发行版环境中启用。通过源码直接运行的 `Mac Face Lock.app` 不执行旧版检测或清理，避免开发版本把自身识别为待删除对象。

发行版初始化顺序固定为：

1. 建立发行版自己的 Application Support 目录。
2. 检查是否存在未完成的旧版清理记录。
3. 检测已知源码测试版。
4. 必要时取得用户的不可恢复操作确认并完成清理。
5. 只有清理状态为“不需要清理”或“清理成功”，才允许查询、安装或修复发行版后台服务。
6. 继续权限中心、重新录入本人、安全测试和发行版服务健康验证。

在第 4 步完成前，`SetupCoordinator` 不得调用 `ServiceManager` 查询、安装、修复或卸载共享标签的服务，保护功能必须保持关闭。

## 4. 已知源码版身份

### 4.1 固定服务和文件

只识别当前用户目录中的以下两个 plist：

- `~/Library/LaunchAgents/com.wuyi.mac-face-lock-agent.plist`
- `~/Library/LaunchAgents/com.wuyi.mac-face-lock-status.plist`

它们必须分别包含精确标签：

- `com.wuyi.mac-face-lock-agent`
- `com.wuyi.mac-face-lock-status`

两个 plist 都必须是当前用户拥有的普通文件，不得是符号链接、硬链接或特殊文件，单个文件不得超过 1 MiB。

### 4.2 同根验证

两个 plist 的 `WorkingDirectory` 必须是同一个绝对源码根目录。源码根必须位于当前用户主目录内；该根目录及其从用户主目录开始的每个现有路径组件都不得是符号链接，且根目录必须由当前用户拥有。

Agent plist 的 `ProgramArguments` 必须精确对应以下已知形式之一：

```text
<源码根>/dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent
<源码根>
```

```text
<源码根>/dist/Mac Face Lock Agent.app/Contents/MacOS/MacFaceLockAgent
-u
agent.py
```

Status plist 的 `ProgramArguments` 必须精确对应以下已知形式之一：

```text
<源码根>/dist/Mac Face Lock.app/Contents/MacOS/MacFaceLock
<源码根>
```

```text
<源码根>/dist/Mac Face Lock Status.app/Contents/MacOS/MacFaceLockStatus
<源码根>
```

两个 plist 的日志路径也必须精确对应：

```text
Agent StandardOutPath:    <源码根>/logs/agent.out.log
Agent StandardErrorPath:  <源码根>/logs/agent.err.log
Status StandardOutPath:   <源码根>/logs/status.out.log
Status StandardErrorPath: <源码根>/logs/status.err.log
```

不得通过日志路径、可执行文件路径或目录名称推断其他根目录。

除上述路径差异外，检测器只接受仓库中已知的当前版和历史版 plist 结构。历史 Agent 允许 `PYTHONPATH` 指向同一源码根内的 `.venv/lib/pythonX.Y/site-packages`；任何指向源码根外的 `PYTHONPATH`、额外可执行参数或未知字段组合都进入 `ambiguous`。已知结构以固定测试夹具版本化，不对任意相似 plist 做模糊匹配。

### 4.3 检测结果

检测只有四种结果：

- `notFound`：两个源码 plist 都不存在，或现有 Agent plist 被严格识别为当前发行版模板且不存在旧 Status plist。
- `confirmedLegacy`：两个源码 plist 同时存在并通过全部身份与同根验证。
- `ambiguous`：只存在其中一个源码 plist、两个 plist 根目录不一致、发行版 Agent 与源码 Status 混合存在，或任何字段不符合已知结构。
- `cleanupIncomplete`：存在由本发行版创建且验证通过的未完成清理记录。

`ambiguous` 不执行任何删除，首次设置保持阻塞，并显示诊断信息和手工处理说明。产品不得把未知结构“尽量”归类为源码版。

## 5. 用户确认

检测到 `confirmedLegacy` 时，准备检查页显示：

> 检测到旧版 Mac Face Lock。继续将停止旧版后台服务，并永久删除旧版人脸模板、配置、活动记录、证据、日志和旧应用。源码、Git 历史、文档、脚本和 Python 开发环境不会删除。此操作不可恢复。

提供两个操作：

- `清除旧版并继续`
- `取消`

取消只结束本次操作，不停止服务、不写清理记录、不删除文件，也不允许越过该步骤启用发行版保护。

确认后先完成全量预检。预检全部通过前不得停止服务、写清理记录或删除任何旧版文件。

## 6. 删除范围

在经过验证的源码根目录内，仅允许删除以下精确目标：

- `config/config.json`
- 整个 `data/` 目录树
- 整个 `logs/` 目录树
- `dist/Mac Face Lock Agent.app`
- `dist/Mac Face Lock.app`
- `dist/Mac Face Lock Status.app`

在用户 LaunchAgents 目录内，仅允许删除：

- `com.wuyi.mac-face-lock-agent.plist`
- `com.wuyi.mac-face-lock-status.plist`

不存在的允许目标视为已完成。清理器不得删除 `config/`、`dist/` 或源码根目录本身，也不得扩展允许列表。

因此以下内容明确保留：

- 所有 Python、Swift、Shell 和其他源码文件；
- `.git/`、`.worktrees/` 和 Git 历史；
- `.venv/` 及其他未列入允许列表的开发环境；
- `README.md`、`docs/`、测试、构建脚本和配置模板；
- `dist/` 中任何不在精确允许列表内的其他文件；
- 当前发行版 Application Support 中的首次设置状态和新数据。

## 7. 全量预检与安全约束

清理前必须先生成固定允许列表，并对全部现有目标完成无副作用预检：

- 使用不跟随符号链接的文件系统检查。
- 目标及目标目录树内不得包含符号链接、硬链接或 FIFO、Socket、设备文件等特殊文件。
- 普通文件必须由当前用户拥有；目录必须由当前用户拥有且不能越出已验证源码根。
- 所有规范化路径必须仍是允许目标本身或允许目录树的后代。
- 最多检查 50,000 个目录项，普通文件逻辑大小合计最多 20 GiB。
- 遇到权限错误、目录在遍历中发生身份变化、超过限制或任何无法证明安全的情况，预检失败。
- 预检结束时再次核对两个 plist 及源码根目录的设备号和 inode，确认检测期间没有被替换。

任一预检失败都必须保持零删除、零停服，并进入 `ambiguous` 阻塞状态。

## 8. 清理执行与重试

用户确认且预检通过后，发行版先在自己的 Application Support 目录写入权限为 `0600` 的版本化清理记录。记录只保存已验证源码根路径、根目录设备号和 inode、固定目标清单、当前阶段和错误摘要，不复制旧配置或生物特征数据。

执行顺序固定为：

1. 通过当前用户的 `launchctl` 先停止 `com.wuyi.mac-face-lock-status`，再停止 `com.wuyi.mac-face-lock-agent`。
2. 验证两个任务均未加载；“任务原本不存在”可视为成功，其他停止或验证错误立即阻塞。
3. 重新核对根目录身份和所有剩余目标的安全边界。
4. 删除源码根内的允许数据和应用目标。
5. 删除旧 Status plist，再删除旧 Agent plist。
6. 验证两个任务未加载、两个 plist 不存在、源码根内所有允许目标不存在。
7. 将清理记录标记完成，然后进入全新的权限与录脸流程。

本操作不承诺文件系统事务式回滚。执行开始后的错误可能留下部分已删除状态。出现这种情况时：

- 状态变为 `cleanupIncomplete`；
- 保护功能和发行版服务操作继续被阻塞；
- 界面只提供“重试清理”和诊断信息，不提供恢复；
- 重试只能使用本发行版此前创建且通过权限、结构和根目录身份验证的清理记录；
- 重试再次验证所有剩余目标，不因目标已经不存在而失败；
- 清理完成后删除清理记录中的路径清单，只保留不含旧路径的完成状态。

没有有效清理记录但只剩单个旧 plist 的情况仍属于 `ambiguous`，不得猜测这是本应用造成的中断。

## 9. 组件边界

新增一个聚焦组件 `LegacyInstallCleaner`，负责：

- 安全读取和分类两个 LaunchAgent plist；
- 验证源码根与精确允许列表；
- 生成预检结果；
- 在用户确认后执行停服、删除、验证和幂等重试；
- 输出不包含人脸模板或配置内容的诊断摘要。

`LegacyInstallCleaner` 不负责权限请求、本人录入、安全测试或发行版服务安装。

`SetupCoordinator` 只编排状态：

- 发行版准备阶段先等待清理结果；
- `confirmedLegacy` 显示确认界面；
- `ambiguous` 或 `cleanupIncomplete` 阻止后续步骤；
- `notFound` 或清理成功后才进入现有首次设置流程。

`ServiceManager` 继续使用 `com.wuyi.mac-face-lock-agent` 作为发行版 Agent 标签，但只在清理门禁解除后运行。发行版不再安装旧 `com.wuyi.mac-face-lock-status` LaunchAgent。

## 10. 卸载与后续行为

- 发行版卸载只停止并删除发行版自己的 Agent 服务。
- 卸载不会恢复源码版服务、源码版 plist 或任何已删除数据。
- 清理成功后再次安装发行版，不重复显示旧版清理确认。
- 如果用户之后重新运行源码版安装脚本，那是一次新的显式源码安装，不属于自动恢复。
- 当前发行版数据仍按发行版自己的卸载和隐私策略处理，不与本次旧源码清理混合。

## 11. 文案与文档调整

现有“原目录和数据将保持不变”说明必须移除，因为它与本设计冲突。

README 和首次设置说明必须明确区分：

- 未使用过源码测试版：直接完成权限、录脸和安全测试。
- 检测到已知源码测试版：确认后永久清除旧运行数据和旧服务，再重新设置。
- 检测结果有歧义：不自动删除，按照诊断说明手工处理。

公开文档继续使用“开源 Beta”措辞，不宣称无风险迁移或可恢复升级。

## 12. 测试与验收

实施遵循先写失败测试、再写生产代码的顺序。最低验收包括：

1. 精确识别已知 Agent 与 Status plist、共享源码根、两个已知 Agent 参数形式和两个已知 Status 可执行形式。
2. 两个 plist 均不存在时直接进入新安装；当前发行版 Agent plist 不被当成源码版。
3. 单个 plist、混合发行版/源码版、根目录不一致、未知字段或未知可执行路径进入 `ambiguous`。
4. 只有发行版启用清理器；源码运行模式不会清理自身。
5. 未取得用户确认时不停止服务、不写清理记录、不删除文件。
6. 用户取消后旧服务、plist、配置、数据、日志和应用全部保持原样。
7. 预检遇到符号链接、硬链接、特殊文件、越界路径、替换竞态、权限问题或数量/大小超限时零停服、零删除。
8. 成功清理会停止两个任务，删除两个 plist 和全部精确允许目标，同时用哨兵文件证明源码、`.git`、`.worktrees`、`.venv`、文档、脚本及其他 `dist/` 内容未被删除。
9. 任一执行阶段失败会进入 `cleanupIncomplete`，保护和发行版服务操作保持关闭。
10. 有效清理记录支持幂等重试；篡改、权限错误、根目录身份变化或无记录的残缺安装不会继续删除。
11. `SetupCoordinator` 在清理门禁解除前不调用 `ServiceManager`；解除后仍强制权限、重新录脸、安全测试和服务健康验证。
12. 发行版只在旧 Agent plist 已移除后安装同标签服务，且不安装旧 Status LaunchAgent。
13. 发行版卸载不会恢复旧服务或旧数据。
14. 首次设置、README、测试和 CI 中不再出现“原目录和数据将保持不变”的过时承诺。
15. 全量 Swift、Python、双应用构建、plist、签名、最低 macOS 版本和开源路径策略继续通过。

## 13. 发布边界

本设计完成后仍属于首次开源 Beta 的发布准备工作。GitHub 发布、公开仓库创建和最终 Release 打包继续作为后续独立任务，不在本清理设计中执行。
