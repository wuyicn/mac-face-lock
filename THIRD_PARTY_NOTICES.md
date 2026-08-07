# Third-Party Notices

Mac Face Lock 的项目源码使用 MIT 许可证。源码开发模式由 `scripts/bootstrap.sh` 通过 pip 安装运行依赖；自包含发行包会捆绑这些依赖及其运行所需组件。它们继续受各自许可证约束。

| 组件 | 锁定版本 | 许可证与随包来源文件 | 上游项目 |
| --- | --- | --- | --- |
| CPython runtime | 3.11 | PSF License（`licenses/Python/LICENSE.txt`） | https://www.python.org/ |
| NumPy | 1.26.4 | BSD-3-Clause（`licenses/NumPy/LICENSE.txt`） | https://github.com/numpy/numpy |
| opencv-python wrapper | 4.10.0.84 | MIT（`licenses/opencv-python/LICENSE.txt`） | https://github.com/opencv/opencv-python |
| OpenCV 4.10.0（随 opencv-python 4.10.0.84 wheel 分发） | — | Apache-2.0 及随包第三方声明（`licenses/opencv-python/LICENSE-3RD-PARTY.txt`） | https://github.com/opencv/opencv |
| pynput | 1.8.1 | LGPL-3.0-or-later（`licenses/pynput/COPYING.LGPL`） | https://github.com/moses-palmer/pynput |
| six | 1.17.0 | MIT（`licenses/six/LICENSE`） | https://github.com/benjaminp/six |
| PyObjC suite | 11.1 | MIT（`licenses/PyObjC/LICENSE.txt`） | https://github.com/ronaldoussoren/pyobjc |

发行包中的 PyObjC suite 包括 `pyobjc-core`、
`pyobjc-framework-ApplicationServices`、`pyobjc-framework-Cocoa`、
`pyobjc-framework-CoreText` 和 `pyobjc-framework-Quartz`。这些组件来自同一
PyObjC 11.1 发行套件，随包保存其实际安装 wheel 提供的共同 MIT 许可证文本。

发行构建工具锁定为 PyInstaller 6.21.0（GPL-2.0-or-later，并带有允许分发生成应用的 bootloader 例外）。构建环境还锁定 altgraph 0.17.5、macholib 1.16.4、packaging 26.2、pyinstaller-hooks-contrib 2026.6 与 setuptools 83.0.0；这些构建依赖的实际许可证和声明以各自分发包为准。PyInstaller 本身不会改变被捆绑运行依赖的许可证。

opencv-python 的安装 metadata 使用简化的 Apache 2.0 标签，但 wheel 内
`LICENSE.txt` 是 wrapper 的 MIT 文本；随 wheel 分发的 OpenCV 二进制及其他
组件声明记录在 `LICENSE-3RD-PARTY.txt`。构建脚本只复制当前锁定环境实际安装
分发包中的许可证文件，不生成或改写许可证正文。完整版权声明及随 wheel
包含的其他组件以发行包 `Contents/Resources/licenses/` 中的文本为准。
