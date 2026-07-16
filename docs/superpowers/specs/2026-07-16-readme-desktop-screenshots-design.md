# README 桌面端截图设计

日期：2026-07-16

状态：已确认，已实施

## 目标

让访问 GitHub 仓库的用户在阅读安装说明前，直接看到 Mac Face Lock 的桌面控制中心和外观设置界面。

## 排版

在 README 顶部安全提醒之后、系统要求之前增加“桌面端界面预览”章节。两张图片按纵向顺序全宽展示，避免并排缩小后难以阅读中文界面细节。

展示顺序：

1. “保护概览”：`docs/design-references/mac-face-lock-overview-liquid-glass.png`
2. “外观设置”：`docs/design-references/mac-face-lock-appearance-settings.png`

每张图片使用简短的三级标题和准确的中文替代文本。图片通过仓库相对路径引用，确保 GitHub README、克隆后的本地 Markdown 阅读器和分支预览都能解析。

## 范围

- 产品实现仅修改 `README.md`；设计与计划文档可记录决策与进度。
- 不修改、压缩或重新生成现有图片。
- 不改动产品代码、安装流程、版本号或发布状态。

## 验证

- 检查两个相对图片路径均指向已跟踪文件。
- 运行 Markdown 行尾与 Git 差异检查。
- 推送后打开 GitHub README，确认两张图片可见、顺序正确且页面没有破图。
