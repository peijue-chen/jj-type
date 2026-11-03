# Changelog

JJType 的所有可见变更都记录在这里。版本号固定三位 `MAJOR.MINOR.PATCH`
（见 AGENTS.md → Versioning & Changelog）。

- `PATCH`（1.1.0 → 1.1.1）：修 bug / 内部重构，用户可见行为不变
- `MINOR`（1.1.1 → 1.2.0）：新增功能或用户可见行为变化，PATCH 归零
- `MAJOR`（1.2.0 → 2.0.0）：不兼容改动 / 大版本

## [1.1.2] — 2026-11-03

### Changed

- `build-release.sh` 恢复可读的构建日志：不再用 `-quiet` 把成功构建吞成空白。
  默认输出：版本/架构横幅、按架构的编译进度、签名、warning/error 原文、
  `** BUILD SUCCEEDED **`、耗时与产物路径；增量构建会明确提示"没有需要重新
  编译的文件"。`VERBOSE=1 ./build-release.sh` 输出原始完整日志。编译失败时
  给出明确的"编译失败（exit N）"提示并保留退出码。

## [1.1.1] — 2026-11-03

### Fixed

- Release 构建的 Swift 6 并发警告：`CaptureOverlayView.prepareMosaic()` 在
  detached task 里再嵌 `MainActor.run`，内层闭包引用了 weak `self` 变量
  （`reference to captured var 'self' in concurrently-executing code`，Swift 6
  语言模式下是 error）。改为外层 MainActor `Task` + `await` detached 结果。
- `build-release.sh` 的 "Stale file ... outside of the allowed root paths" 警告：
  来自旧工作区（`/Desktop/jj-type`）时代留下的派生数据缓存，删除 `./build`
  后重新构建即消失。
- `build-release.sh` 增加 `-destination 'generic/platform=macOS'`，不再输出
  "Using the first of multiple matching destinations"。

## [1.1.0] — 2026-11-03

### Added

- 设置页底部常驻版本号（`JJType 1.1.0 (2)`），取自 bundle 的
  `CFBundleShortVersionString` / `CFBundleVersion`，随每个页面一起显示。
- 本 CHANGELOG 与版本规范（AGENTS.md），此后每次改动都要升版本并记一条。

### Changed

- 双击选区从「只复制」改为「复制 + 保存」：图片进剪贴板的同时写入截图目录，
  一条 toast 同时报告两件事（`已复制并保存 · JJType-20261103-132355.png`）。
- 「保存」按钮成功后也有 toast 反馈（此前是静默的）。
- 保存失败且图片已在剪贴板时，提示改为「已复制，但保存截图失败」，不再让人
  以为整张图丢了。
- 版本号改为三位格式：`MARKETING_VERSION = 1.1.0`、`CURRENT_PROJECT_VERSION = 2`，
  并在 Info.plist 中显式引用这两个构建设置。

### Fixed

- 内联文字输入时 ⌘C / ⌘S / ⌘Z 被截图会话抢走：复制整张图、关闭会话并丢掉
  刚输入的文字。现在第一响应者是输入框时快捷键归输入框。
- 中文文字标注的脏矩形偏小，撤销 / 擦除后残留半截字形（改用实测文字宽度）。
- 拖拽新选区时旧窗口悬停框残留在屏幕上；`mouseExited` / 拖拽结束会整屏重绘
  （改为只重绘变化的那两个矩形）。
- 共享 field editor 的透明背景未还原，可能导致设置页输入框背景丢失。
- 拖成一条线的矩形 / 椭圆不绘制却仍提交，锁死选区并占用一个撤销步。
- 选中马赛克工具时在主线程预生成整屏像素图造成卡顿（移到后台任务）。
- `AXUIElement` 强转外部进程返回值存在崩溃风险（先校验 CF 类型）。

## [1.0.0] — 2026-11-02

首个可用版本（基线）：

- 菜单栏常驻，全局快捷键：选中文字翻译 / 纠正英文 / 截图。
- OpenAI 兼容接口（Base URL + API Key + 模型名，Key 存钥匙串），连接测试。
- 截图：多屏冻结、窗口悬停高亮、8 个缩放手柄。
- 9 种标注工具（矩形 / 椭圆 / 箭头 / 画笔 / 高亮 / 马赛克 / 文字 / 序号 / 橡皮），
  撤销重做、6 色 3 粗细、字体与字号、高亮透明度。
- OCR（Vision）识别文字到剪贴板，钉图常驻，保存 PNG / JPEG 到指定目录。
