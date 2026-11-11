---
name: launch-at-login
overview: 用 SMAppService 实现「开机自启」，并在设置里新增「通用」页提供开关、真实状态显示与登录项设置入口。
todos:
  - id: launch-service
    content: 新增 Core/LaunchAtLoginService，封装 SMAppService 状态、注册/注销与打开登录项设置
    status: completed
  - id: settings-page
    content: 设置新增「通用」页：开机自启勾选框、彩色状态标签、打开登录项设置按钮
    status: completed
    dependencies:
      - launch-service
  - id: state-sync
    content: 进入通用页重读系统状态，失败回滚勾选并显示错误，刷新后自适应窗口高度
    status: completed
    dependencies:
      - settings-page
  - id: docs-build
    content: 更新 CHANGELOG/AGENTS，构建号升至 44，编译并验证开关读写与状态显示
    status: completed
    dependencies:
      - state-sync
---

## 用户需求

为 JJType 增加「开机自启」能力，并在设置界面提供开关。

## 产品概述

菜单栏常驻工具最合理的启动方式就是跟随系统登录自动运行。本次在设置中新增一个「通用」页，用勾选框一键开启/关闭开机自启，状态始终以 macOS 登录项的真实状态为准。

## 核心功能

- 设置新增「通用」页（放在侧栏第一位），内含「开机时自动启动 JJType」勾选框，默认关闭
- 勾选即注册为系统登录项，取消勾选即移除；开关状态实时反映系统登录项的真实状态（用户可能在系统设置里手动关掉）
- 系统层面需要用户确认时（登录项被关闭 → 状态为「需要批准」），页面显示状态提示与「打开登录项设置」按钮，一键直达 系统设置 → 通用 → 登录项，绝不静默失败
- 注册失败时在页面上以红色状态文案给出原因（如应用被隔离、签名异常），可重试
- 页面附说明：登录项在系统设置中可见可管理；建议先把 JJType.app 放进「应用程序」文件夹再开启，否则登录项会指向当前所在目录

## 视觉与交互

沿用现有设置窗口风格：圆角分组卡片 + 勾选框 + 灰色小字说明；状态标签用绿色表示已开启、灰色表示未开启、橙色表示需要用户在系统设置中批准。

## 技术栈

- 语言与框架：Swift 5（语言模式）/ AppKit，零第三方依赖
- 新增系统框架：`ServiceManagement`（`SMAppService`，macOS 13+；工程 `MACOSX_DEPLOYMENT_TARGET = 14.0`，可直接使用）
- 现有签名配置已满足要求：`CODE_SIGN_IDENTITY = "Apple Development"` + `DEVELOPMENT_TEAM = 36RXHYW79N`（`SMAppService.mainApp.register()` 需要有效签名，ad-hoc 会失败）

## 实现思路

用 `SMAppService.mainApp` 作为唯一真相源，**不再用 UserDefaults 存一个布尔值**——否则用户在「系统设置 → 通用 → 登录项」里手动关掉后，App 内的开关会与系统状态不一致。开关的 initial state 直接读 `SMAppService.mainApp.status`。

- `status == .enabled` → 勾选为 on，绿色「已开启」
- `status == .notRegistered` → off，灰色「未开启」
- `status == .requiresApproval` → off，橙色「已被系统关闭，需在登录项中允许」+「打开登录项设置」按钮（`SMAppService.openSystemSettingsLoginItems()`）
- `status == .notFound` → off，灰色「当前不可用」
- `register()` / `unregister()` 抛错时 catch，把 `error.localizedDescription` 写进状态标签（红色）并同时露出「打开登录项设置」按钮

不用已废弃的 `LSSharedFileList`，也不写 `~/Library/LaunchAgents` plist：官方现代方案还能让条目在系统设置里对用户可见、可管理，正好对上「如果需要权限」的诉求（登录项不涉及 TCC，无需新建权限引导窗口，用内联状态标签 + 出口按钮即可，风格与 `Permissions/AccessibilityPermission.swift` 的中文引导保持一致）。

性能：`status` 是同步轻量属性，只在页面构建/页面切入时读取一次（O(1)），不做轮询；注册/注销为用户点击触发的一次性系统调用。

## 架构设计

沿用「Service 层 + 设置页」的现有结构，不新增架构模式：

```
SettingsWindowController
   └── makeGeneralPage()  ──读取/写入──▶  LaunchAtLoginService (enum, 无状态)
                                            └── SMAppService.mainApp (系统)
```

关键点：`SettingsWindowController.specs` 与 `pages` 是**按索引一一对应**的（侧栏点击、`selectPage(index)` 都靠下标）。新增页面必须同位置插入两者；同时 `init` 里的 `selectPage(0)` 要改为按标题定位「AI 服务」，保持默认页不变。`selectTerminalSection()` 已按标题查找「终端」，不受插入影响。

## 目录结构

```
jj-type/
├── Core/
│   └── LaunchAtLoginService.swift        # [NEW] 开机自启的唯一封装。负责：读 SMAppService.mainApp.status
│                                          #       （映射为 isEnabled + 中文状态文案）、setEnabled(_:) throws
│                                          #       （register/unregister，成功后返回新状态）、openSystemSettings()
│                                          #       （openSystemSettingsLoginItems）、isInApplicationsFolder
│                                          #       （Bundle.main.bundleURL 判断是否在 /Applications 或 ~/Applications，
│                                          #       用于提示登录项会指向当前路径）。需 import ServiceManagement；
│                                          #       注释用英文；不做缓存、不做轮询。
├── Settings/
│   └── SettingsWindowController.swift    # [MODIFY] 1) 文件头注释 six → seven 页并列出「通用」；
│                                          #       2) specs 第 0 项插入 PageSpec(通用, symbol: "gearshape.fill", 沿用现有渐变配色)；
│                                          #       3) pages 数组同位置插入 makeGeneralPage()；
│                                          #       4) init 中 selectPage(0) 改为按标题定位 "AI 服务"；
│                                          #       5) 新增 makeGeneralPage()：Theme.card() + makeSectionHeader("启动")
│                                          #          + 勾选框「开机时自动启动 JJType」(action: launchAtLoginToggled)
│                                          #          + 状态标签（绿/灰/橙/红）+ 默认隐藏的「打开登录项设置」按钮
│                                          #          + makeHint 说明（登录项位置、建议放 /Applications、Xcode 调试时
│                                          #          注册的是调试产物路径）；
│                                          #       6) 新增 launchAtLoginToggled(_:)：调 service，失败回滚勾选态并把错误写进状态标签；
│                                          #       7) 新增 refreshLaunchAtLoginState()：重读系统状态刷新勾选框/标签/按钮，
│                                          #          在 show(page:) 进入通用页时调用（用户在系统设置改过也能同步），
│                                          #          并在状态文字变化后触发 resizeWindowToFit()。
├── CHANGELOG.md                          # [MODIFY] 1.9.0 段落 Added 追加「开机自启」条目
├── AGENTS.md                             # [MODIFY] Module Map 新增 LaunchAtLoginService 一行；
│                                          #          SettingsWindowController 相关描述补「通用页（开机自启）」
└── jj-type.xcodeproj/project.pbxproj     # [MODIFY] CURRENT_PROJECT_VERSION 43 → 44
```

## 关键接口

```swift
/// Login-item (launch at login) state, backed by SMAppService.mainApp.
/// The system status is the single source of truth — never cached in
/// UserDefaults, or the toggle drifts from what System Settings shows.
enum LaunchAtLoginService {
    enum State {
        case enabled          // 已开启
        case notRegistered    // 未开启
        case requiresApproval // 被用户在「登录项」里关闭
        case unavailable      // 系统不支持 / 找不到
    }

    static var state: State
    static var isEnabled: Bool
    /// true when the bundle lives in /Applications or ~/Applications.
    static var isInApplicationsFolder: Bool
    /// Registers / unregisters the login item. Throws the underlying
    /// SMAppService error so the caller can surface it verbatim.
    static func setEnabled(_ enabled: Bool) throws
    static func openSystemSettings()
}
```

## 执行注意事项

- `pages`/`specs` 索引一致性是本次最大回归风险：两处必须同位置插入，且默认页改为按标题查找。
- 勾选框动作里**先调用服务再刷新 UI**，失败时把 `sender.state` 回滚为真实状态（读服务），避免出现「勾上但没生效」的假象。
- 状态标签文案变化会改变卡片高度，刷新后调用 `resizeWindowToFit()`（现有方法）以免文字被裁。
- 注册/注销是主线程轻量系统调用，无需异步；但必须在 `do/catch` 内，且错误文案用中文前缀 + 原始描述，便于排查。
- 关闭 Xcode 调试场景不要特殊处理，只在 hint 里说明即可。
- 文档与构建号同步；构建产出 `apps/<timestamp>/JJType.app`，需提示用户安装到 /Applications 后再开启开关（否则登录项指向 `apps/` 里的那份）。