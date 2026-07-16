# Third-Party Notices

Mac Face Lock 的项目源码使用 MIT 许可证。下列直接 Python 依赖由 `scripts/bootstrap.sh` 通过 pip 单独安装，不包含在本项目源码中；这些依赖及其随 wheel 分发的组件继续受各自许可证约束。

| 组件 | 锁定版本 | 许可证与随包来源文件 | 上游项目 |
| --- | --- | --- | --- |
| NumPy | 1.26.4 | BSD-3-Clause（`LICENSE.txt`） | https://github.com/numpy/numpy |
| opencv-python wrapper | 4.10.0.84 | MIT（`LICENSE.txt`） | https://github.com/opencv/opencv-python |
| OpenCV 4.10.0（随 opencv-python 4.10.0.84 wheel 分发） | — | Apache-2.0（`LICENSE-3RD-PARTY.txt`） | https://github.com/opencv/opencv |
| pynput | 1.8.1 | LGPL-3.0-or-later（`COPYING.LGPL`） | https://github.com/moses-palmer/pynput |

opencv-python 的安装 metadata 使用简化的 Apache 2.0 标签，但 wheel 内 `LICENSE.txt` 是 wrapper 的 MIT 文本；随 wheel 分发的 OpenCV 二进制及其他组件声明记录在 `LICENSE-3RD-PARTY.txt`。完整许可证文本、版权声明以及 wheel 包含的其他组件，请查看对应上游项目和实际安装的分发包。本文件不复制大段第三方许可证，也不改变任何第三方软件的许可条件。
