# README Desktop Screenshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checklist syntax for tracking.

**Goal:** 在 GitHub README 顶部以全宽纵向布局展示保护概览和外观设置两张桌面端界面图。

**Architecture:** 产品实现仅修改 `README.md`；设计与计划文档可记录决策与进度。在安全提醒之后、系统要求之前插入独立预览章节。使用仓库相对路径引用现有已跟踪 PNG，不复制或重新编码图片。

**Tech Stack:** GitHub Flavored Markdown、Python 3 标准库、Git

## Global Constraints

- 产品实现仅修改 `README.md`；设计与计划文档可记录决策与进度。
- 不修改、压缩或重新生成现有图片。
- 不改动产品代码、安装流程、版本号或发布状态。
- 图片顺序固定为保护概览、外观设置。
- 图片必须使用仓库相对路径和准确中文替代文本。

---

### Task 1: 在 README 展示桌面端界面

**Files:**
- Modify: `README.md:9`
- Verify: `docs/design-references/mac-face-lock-overview-liquid-glass.png`
- Verify: `docs/design-references/mac-face-lock-appearance-settings.png`

**Interfaces:**
- Consumes: 两个已跟踪 PNG 的仓库相对路径。
- Produces: README 中标题为“桌面端界面预览”的完整章节。

- [x] **Step 1: 运行内容检查并确认当前 README 缺少预览章节**

```bash
python3 - <<'PY'
from pathlib import Path

text = Path("README.md").read_text(encoding="utf-8")
expected = (
    "## 桌面端界面预览",
    "### 保护概览",
    "![Mac Face Lock 桌面端保护概览](docs/design-references/mac-face-lock-overview-liquid-glass.png)",
    "### 外观设置",
    "![Mac Face Lock 桌面端外观设置](docs/design-references/mac-face-lock-appearance-settings.png)",
)
for item in expected:
    assert item in text, f"README missing: {item}"
PY
```

Expected: FAIL with `README missing: ## 桌面端界面预览`.

- [x] **Step 2: 在安全提醒之后插入完整预览章节**

```markdown
## 桌面端界面预览

### 保护概览

![Mac Face Lock 桌面端保护概览](docs/design-references/mac-face-lock-overview-liquid-glass.png)

### 外观设置

![Mac Face Lock 桌面端外观设置](docs/design-references/mac-face-lock-appearance-settings.png)
```

- [x] **Step 3: 验证内容、顺序和图片文件**

```bash
python3 - <<'PY'
from pathlib import Path

readme = Path("README.md").read_text(encoding="utf-8")
items = (
    "## 桌面端界面预览",
    "### 保护概览",
    "![Mac Face Lock 桌面端保护概览](docs/design-references/mac-face-lock-overview-liquid-glass.png)",
    "### 外观设置",
    "![Mac Face Lock 桌面端外观设置](docs/design-references/mac-face-lock-appearance-settings.png)",
)
positions = [readme.index(item) for item in items]
assert positions == sorted(positions)
assert readme.index("> 安全提醒") < positions[0] < readme.index("## 系统要求")
for path in (
    Path("docs/design-references/mac-face-lock-overview-liquid-glass.png"),
    Path("docs/design-references/mac-face-lock-appearance-settings.png"),
):
    assert path.is_file(), f"missing image: {path}"
PY
git diff --check
```

Expected: exit 0 with no output.

- [x] **Step 4: 提交 README 更新**

```bash
git add README.md
git commit -m "docs: add desktop screenshots to README"
```

- [x] **Step 5: 推送分支并确认 GitHub README 图片可见**

```bash
git push -u origin agent/readme-desktop-screenshots
```

Expected: 分支推送成功；GitHub README 显示两张图片，顺序为保护概览、外观设置。
