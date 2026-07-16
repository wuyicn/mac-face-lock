# Mac Face Lock 融合界面视觉验收

日期：2026-07-14
验收对象：主项目真实安装的 `dist/Mac Face Lock.app`
参考：`docs/design-references/mac-face-lock-overview-liquid-glass.png`、`docs/design-references/mac-face-lock-appearance-settings.png`

## 结果

**PASS**

## 已检查

- 原生 macOS 单窗口与菜单栏融合架构正常，窗口标题为 `Mac Face Lock`。
- 概览页呈现 210pt 玻璃侧边栏、保护状态、暂停入口、今日活动和右侧策略栏。
- 活动页正确显示本地活动列表、时间、详情以及证据目录/日志入口。
- 设置页提供跟随系统、浅色、深色三种显示模式。
- 深海蓝、守护绿、紫晶三套强调色均可选择并立即更新玻璃染色与控件强调色。
- 安全状态色保持独立：正常为绿、警示为橙、危险/锁屏为红，不随主题色改变。
- 深色玻璃模式对比度、卡片层级和文字可读性正常；验收后已恢复“跟随系统 + 深海蓝”。
- 保护、记录、设置导航和主题卡均向 VoiceOver 暴露选中状态。
- 真实 LaunchAgent 中 Python Agent 与融合界面均为 `running`，且使用各自预期可执行文件。

## 结论

融合版达到选定视觉方向，可以作为当前 Mac Face Lock 默认桌面客户端。

## 0.1.0-beta 源码发布验收

日期：2026-07-16

本地技术门禁：**PASS**

公开发布：**HOLD**

### 命令与结果

- `.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v`：136 项测试通过，0 failure，0 error，0 skip。
- 三组 `xcrun swiftc` 可执行测试：Local Store smoke、Project Locator 和 Agent Launcher 全部打印通过信息；完整 SwiftUI/AppKit 源码 typecheck 退出 0。
- `scripts/build-app.sh` 与 `scripts/build-status-app.sh`：两个 app bundle 构建成功；源、LaunchAgent 和 bundle plist 全部通过 `plutil -lint`。
- `codesign --verify --deep --strict` 与 `xcrun vtool -show-build`：两个 ad-hoc 签名均验证通过，两个 Mach-O 均精确报告 `minos 12.0`。
- `git archive HEAD`：在独占的“中文 + 空格”临时目录中重新构建两个 app、渲染两个 LaunchAgent、lint 生成的 plist 并验证签名，全部通过；产物无开发者 home 路径。
- `git grep`、`git ls-files`、跟踪内容策略与高置信 secret 特征扫描：当前跟踪快照未发现开发者 home 路径、私有运行数据、密钥/证书文件或密钥值；CI 危险命令策略测试通过。
- `git diff --check` 与工作树清洁性检查：验收文档提交前仅有本节为意图内变更。

### 发布保留项

- 完整 Git 历史仍包含开发者 home 路径的早期版本，并使用了本机或占位 Git 邮箱。当前跟踪快照合格不代表公开历史合格。
- 公开 GitHub 仓库、远程、托管 CI 运行与 private vulnerability reporting 尚未创建、启用或实测。
- 在用户提供预期的公开 GitHub 身份并明确授权前，不改写历史、不创建远程、不 push，也不创建 `v0.1.0-beta` 标签。
- 本次验收未运行 `scripts/install-launchagent.sh`，未触发摄像头、锁屏或用户运行数据流程。
