# Contributing

感谢为 Mac Face Lock 源码 Beta 提交改进。开始前请先阅读 `README.md` 和 `SECURITY.md`。公开仓库的 private vulnerability reporting 尚未启用并实测前，不存在公开私报入口；不要把未修复漏洞或敏感信息提交到公开 Issue。

## 开发流程

1. 从最新开发分支创建小而聚焦的分支。
2. 行为变更先添加失败测试，再实现最小修复。
3. 更新与用户行为相关的 README、CHANGELOG 或安全说明。
4. 在 Pull Request 中说明动机、风险、验证结果和任何未解决的限制。

运行依赖变更必须同时更新 `requirements.txt`、`requirements-lock.txt` 和 `THIRD_PARTY_NOTICES.md`；发行构建依赖还要更新 `requirements-build.txt`、`requirements-build-lock.txt`。不要降低 Python 3.9、Apple Silicon 或 macOS 12 的公开兼容基线，除非变更经过明确讨论。

## 隐私和安全要求

提交必须保留隐私安全默认值：本地处理、摄像头故障 fail-open、外部通知关闭、屏幕截图关闭，以及卸载时保留用户数据。任何改变这些默认值的提案都必须先说明威胁模型和迁移影响。

禁止提交或粘贴真实运行数据，包括但不限于：

- `data/owner_face.npy` 或任何真实人脸模板；
- `data/evidence/` 中的照片或屏幕截图；
- `logs/`、状态文件、活动记录或通知负载中的个人信息；
- 开发者主目录、密钥、令牌、设备标识或本机 LaunchAgent 产物。

测试夹具必须使用合成、匿名且可公开的数据。

## 完整验证

提交 Pull Request 前，在 Apple Silicon Mac 上从项目根目录运行完整验证：

```bash
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v

xcrun swiftc -parse-as-library \
  src/app/Models.swift src/app/LocalJSONStore.swift \
  tests/swift/LocalStoreSmokeTests.swift \
  -o /tmp/mac-face-lock-store-tests
/tmp/mac-face-lock-store-tests

xcrun swiftc -parse-as-library -DTESTING \
  src/app/ProjectLocator.swift tests/swift/ProjectLocatorTests.swift \
  -o /tmp/mac-face-lock-project-locator-tests
/tmp/mac-face-lock-project-locator-tests

xcrun swiftc -parse-as-library -DTESTING \
  src/agent-launcher/main.swift tests/swift/AgentLauncherPathTests.swift \
  -o /tmp/mac-face-lock-agent-launcher-tests
/tmp/mac-face-lock-agent-launcher-tests

xcrun swiftc -parse-as-library -typecheck \
  src/app/*.swift -framework AppKit -framework SwiftUI

plutil -lint src/app/Info.plist
plutil -lint \
  launchd/com.wuyi.mac-face-lock-agent.plist \
  launchd/com.wuyi.mac-face-lock-status.plist

scripts/build-app.sh
scripts/build-status-app.sh
codesign --verify --deep --strict "dist/Mac Face Lock Agent.app"
codesign --verify --deep --strict "dist/Mac Face Lock.app"
```

Pull Request 必须附上完整验证结果。若某项无法运行，请清楚说明原因和未验证风险，不能用部分测试结果代替完整验证。

涉及发行包的 Pull Request 还必须运行 `scripts/build-release.sh`，验证 ZIP 的 SHA-256、临时签名、arm64 架构、macOS 12 最低版本、内置运行组件与解压后的策略测试。发布工作流只产生供人工验收的构件；不得在未完成真实新账号验收、Developer ID 签名和 Apple 公证前自动创建 GitHub Release。
