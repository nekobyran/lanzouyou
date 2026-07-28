# LanzouYOU

LanzouYOU 是面向 Windows 与 Android 的 Flutter + Rust 蓝奏云文件管理客户端。Flutter 共享 Material 3 UI、导航和客户端状态；Rust shared core 负责 Woozooo 协议、解析、校验、传输与会话一致性。

> Woozooo 管理端属于未公开 Web 协议，可能随时变化。README 只给出当前能力摘要；准确的接口、实测范围和风险以[架构与 API 状态文档](../../docs/lanzouyou-api.md)为准。

## 架构

```text
Flutter UI / controllers
  └─ Dart isolate + JSON FFI envelope
       └─ lanzouyou_dispatch / lanzouyou_free
            └─ Rust session / parser / transfer / HTTP
                 └─ Woozooo Web 私有协议
```

- Flutter：`lib/`
- Dart FFI：`lib/services/rust_cloud_service.dart`
- Rust core：`native/lanzouyou_core/`
- 本地应用设置：`lib/services/app_settings_store.dart`；运行时文件位于平台应用支持目录下的 `data/settings/app.json`
- 自动图标 sidecar 查找：`lib/services/icon_source_locator.dart`；解码、提取与压缩由 Rust `prepare_icon` 操作负责
- 隐私安全的离线图标批处理：`tool/prepare_local_icon_batch.py`
- 自定义软件库生成器：`lib/pages/library_builder/`；窄屏底栏与宽屏侧栏提供一级“软件库”空白新项目入口，文件夹菜单继续提供带当前分享信息的快捷入口
- 可配置 Flutter 成品壳：[`../LanzouLibraryShell/`](../LanzouLibraryShell/)
- 维护者模板构建与最终用户重打包分别使用 `command/Build-LanzouLibraryTemplates.ps1`、`command/Build-CustomLanzouLibrary.ps1`

所有 Rust 调用都应由 Dart isolate 执行，不能阻塞 UI isolate。Rust 会话和当前传输队列按账号串行，避免并发 Cookie 更新互相覆盖；`operation_status`、`operation_cancel`、`operation_forget` 直接访问有界操作注册表，不等待管理会话或公开软件库长操作释放锁。

### 本地设置与动效

主题与“减少动效”是实际可读写的本地设置，不保存在页面控制器的临时字段中。设置文件固定使用严格的 `schemaVersion: 1` JSON 契约，写入时先刷新同目录临时文件，再以重命名原子替换 `data/settings/app.json`；截断、未知字段、未来版本或字段类型错误会安全回退到默认设置，不阻止应用启动。连续修改会按顺序持久化，界面先即时生效，最终以最后一次选择为准；保存失败会在设置页显示真实错误状态。

设置数据与登录会话相互独立：退出登录只清除系统安全存储中的会话，不重置主题或“减少动效”。设置页只提供可实际执行的主题选择、减少动效、会话检查和退出登录，不放置没有读写路径的介绍性开关或能力说明。

共享 `AppMotion` 提供 fast / medium / slow 时长、Material 3 缓动，以及 fade-through、slide、fade、size、列表进入和选择状态等统一入口。会话恢复、主导航、文件、回收站、传输、软件库生成器和登录页的主要 loading / content / empty / error / cancel / selection 状态均使用共享动效；顶层导航只激活当前页面的 ticker 与语义，同时保留各页面状态。系统 `MediaQuery.disableAnimations` 或用户启用“减少动效”时，共享时长统一降为零，文字、图标、进度与语义仍独立表达状态。

## 当前状态

| 能力 | 状态 | 边界 |
|---|---|---|
| Windows + Android 共用 Flutter UI | 已实现 | 平台壳只加载各自动态库 |
| Windows 简体中文字体渲染 | 已实现 | 保留 Segoe UI 主字体，回退顺序为 `Microsoft YaHei UI → Microsoft YaHei → Segoe UI Symbol`；Android 不注入 Windows 字体；主题、真实设置、动效、控制器、响应式 UI、传输与生成器当前共 75 项 Flutter 测试通过 |
| JSON FFI envelope 与 dispatch 操作 | 已实现 | 共 35 个操作：22 个管理操作、8 个公开软件库操作、2 个离线模板重打包操作、3 个操作控制；当前 185 项 Rust 单元测试与 6 项 dispatch contract 测试通过 |
| 会话安全恢复、文件列表与分页 | 已实现 | Cookie 只持久化到系统安全存储；列表已做授权只读回读 |
| 账号密码登录 | 已实现，生产 FFI 登录与管理冒烟通过 | 当前 Rust FFI 已完成登录、authenticated 会话读取、根目录首屏列表、管理闭环和注销；gzip 管理页已有回归测试。SmartCaptcha/风控交互尚未接入，不能承诺所有环境始终直登 |
| 新建、改名、移动、删除、分享、提取码 | 已实现，生产 FFI 管理冒烟通过 | 临时对象已完成新建、文件/目录移动、改名、分享、提取码设置/清除、删除和回读；带提取码下载仍有上游 405 边界 |
| 简介读取与写入 | 已实现，生产写入与 FFI 管理冒烟通过 | 已在明确授权范围逐项回读；管理冒烟另用临时对象完成写入和回读，文档不保存私有条目 |
| 普通上传、公开下载、回收站单项操作 | 已实现，生产 FFI 管理冒烟通过 | 上传与下载可携带 `operationId`，在传输页显示实时字节进度并可在运行中协作取消；下载使用 `.part` 临时文件并在取消或失败时清理。临时文件已完成上传、公开下载、复制、恢复与永久删除；任意扩展名兼容包、目录递归复制和全局清空回收站仍以本地测试为主 |
| 本地图标查找、提取与压缩 | 已实现，本地测试 | sidecar、直接图片、APK launcher 与 Windows EXE 可输出最大 144×144、严格小于 100,000 字节的 PNG；Android 不提取 EXE |
| Woozooo 文件自定义图标绑定 | 已实现；协议生产写入与 FFI 管理冒烟通过 | `prepare_icon/set_icon` 已贯通；管理冒烟以固定本地图标完成绑定与回读，另一次授权批量操作也验证了 `task 41 → 签名 OSS → task 38(type=2) → task 41` |
| Rust 公开软件库解析与下载 | 已实现 | `library_probe/browse/search/collect/resolve/download/describe/fetch_asset` 覆盖探测、分页浏览、跨源搜索、结果补全、直链解析、真实本地下载、文件简介懒加载和安全图标转码；公共网络共享进程级长寿命 Tokio runtime（2 个 async、最多 8 个 blocking worker），transport 只持 handle，取消不会在析构阶段等待仍执行的系统 DNS；`library_search` 与 `library_download` 可携带 `operationId` 并协作取消。公共会话与管理 Cookie 隔离，`library_fetch_asset` 只访问受信图标源并固定返回严格 `{"mediaType":"image/png","bytesBase64":"..."}`，输出和远端错误不泄露访问码或 Cookie |
| 自定义软件库生成器 | 已实现 | 窄屏 `NavigationBar` 与宽屏 `NavigationRail` 提供一级“软件库”入口，创建零伪造来源的空白新项目；文件夹菜单继续以当前分享信息创建项目。两种入口共用同一真实编辑、保存与离线打包页，配置身份、品牌、图标、公开软件源、功能开关和目标平台 |
| Android / Windows 离线模板重打包 | 已实现 | `library_repackage_android/windows` 只修改预构建 APK 或 Windows x64 便携 ZIP；Android 版 LanzouYOU 同样可以生成 Windows ZIP，不在设备上编译 Flutter/Rust 源码 |

真实自定义图标绑定必须严格小于 100,000 字节，并在同一串行 Cookie jar 内完成 `task 41`、短期 OSS 上传、`task 38(type=2)` 和后置 `task 41` 回读。上传只信任 `imgup.woozooo.com`，回读只信任 `image.dmpdmp.com`；短期表单只保存在内存中。图标失败不会退化成独立云文件上传。

### 真实 FFI 管理闭环

当前 Rust 动态库已使用本次创建的临时对象完成登录、新建目录、上传、简介、提取码设置与清除、固定图标绑定、分享读取、公开下载、改名、文件移动与复制、回收站恢复与永久删除、目录移动和精确清理。测试不操作用户既有条目，也不调用全局清空回收站。

- Woozooo `task=46` 会保留文件扩展名，因此 core 对文件改名只发送目标 stem；目录改名仍发送完整名称。
- 文件从回收站恢复后位于账号根目录；需要回到业务目录时必须再显式移动并回读。
- 提取码管理和无提取码公开下载已分别通过。当前带提取码分享页的边缘 POST 返回 HTTP 405，属于上游限制，尚未端到端打通。

## 自定义软件库生成器

LanzouYOU 在窄屏底栏与宽屏侧栏提供一级“软件库”入口，直接创建没有示例来源的空白新项目；文件夹菜单仍提供“生成软件库”，并沿用当前文件夹的公开分享信息。两个入口共用同一生成页，可配置多个公开软件源，并编辑应用名称、包名、版本、颜色、官网、发布者、固定图标和浏览/搜索/下载/简介开关。

生成器使用同一 `schemaVersion: 2` generation manifest 绑定的两份预构建模板；清单必须恰好声明 Android、Windows 两个目标和两个固定文件，并同时约束 generation `runId`、文件大小与 SHA-256、Rust core ABI 版本/两个固定导出符号和 recipe schema。LanzouYOU 在返回任一模板前会加载并复核整代清单与两份模板的实际字节摘要，只缓存完整验证通过的一代：

- Android：生成自定义 APK，替换运行时配置、应用标识、名称、版本和图标，然后以本机稳定签名身份执行 APK v2 签名。
- Windows：生成 Windows x64 便携 ZIP，替换运行时配置、品牌图标、EXE 名称和版本资源。

Android 版也能生成 Windows ZIP，因为这个过程只重打包已经编译完成的 Windows 模板；它不会在 Android 上运行 Windows 工具链，也不会把 Flutter/Rust 源码重新构建成 Windows 程序。

所有选中目标会先在私有临时作业中完成身份校验和实际文件 SHA-256 复核，再进入一次批量导出。单目标直接导出对应成品；同时选择 Android 与 Windows 时只弹出一次保存操作，得到一个恰含 APK、Windows ZIP 和去密 manifest 的完整包。生成期间可以点“取消生成”；当前目标结束后会立即阻止后续目标和导出，主动取消、保存窗口取消或任一目标失败都不会留下半套外部产物，临时作业也会清理。

最终用户从 UI 或以下脚本生成时，均只使用本地 recipe、预构建模板与预构建 Rust core：

```powershell
pwsh -NoProfile -File .\command\Build-CustomLanzouLibrary.ps1 -RecipePath .\recipe.json
```

该流程不下载文件，不调用 Flutter、Gradle、Cargo，也不使用远程构建。命令行入口会先校验同代 `schemaVersion: 2` 模板 manifest、core ABI 与摘要，多目标全部成功后才以单一目录原子发布。维护者模板脚本同样先在独立 generation staging 中构建并验证 Android/Windows 两份模板，再原子切换整代资源；任一目标失败都保留上一代完整模板。维护者 release 只在 `release/LanzouLibraryShell_templates/release/generations/<runId>/` 保存不可变代，成功后移除 release 根层旧兼容入口。`Build-LanzouLibraryTemplates.ps1` 不能作为最终用户生成入口：

```powershell
pwsh -NoProfile -File .\command\Build-LanzouLibraryTemplates.ps1
```

访问码会被封装进最终成品的运行时配置，只适合公开分享场景，不能视为不可提取的秘密。Android 签名身份丢失后，同一应用标识的旧安装不能直接升级；Windows 便携 EXE 未带商业代码签名，可能受到系统信誉提示。

## 构建与验证

在仓库根目录使用 PowerShell 7：

```powershell
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action PubGet
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action Analyze
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action Test
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action BuildAllDebug
```

统一入口还支持 Android/Windows 的 Debug、Release、安装和运行动作，详见 [`Invoke-FlutterClient.ps1`](../../command/Invoke-FlutterClient.ps1)。`command/flutter-client-*.cmd` 是常用动作的双击入口；`Invoke-LanzouYOU.ps1` 只保留为轻量转发名。Android 端双产物验收脚本会在全部结构、摘要、签名、对齐、身份和可选启动检查通过后，把最终证据原子写入输出目录的 UTF-8 `verification-result.json`；启动失败不会写入或保留 `pass`。产物归档到：

维护者构建环境固定使用 `D:\vibecoding\sdk`；`-Action EnvironmentCheck` 会在 D 盘 TEMP/cache 下真实探测 Flutter、Dart、Cargo、Rustup、Java 与 ADB，并拒绝 C 盘、旧 `.tools` 或跳出 canonical 根的显式覆盖。Windows native 构建还会独立检查 CMake/Ninja/CL/Visual Studio/Windows SDK；任一工具未迁入统一根即在编译前阻断。

- Android：`release/LanzouYOU_Android/<debug|release>/`
- Windows：`release/LanzouYOU_Windows/<debug|release>/`

Windows 字体回退按 Flutter [`TextStyle.fontFamilyFallback`](https://api.flutter.dev/flutter/painting/TextStyle.fontFamilyFallback.html) 的顺序语义配置；Microsoft 的 [Windows Typography](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/typography) 将 Microsoft YaHei UI 列为简体中文 UI 字体。当前 LanzouYOU 75/75 项 Flutter 测试、软件库壳 102/102 项 Flutter 测试、Rust core 185 项单元测试与 6 项 dispatch contract 测试通过。

### LanzouMax 一键发布

固定构建产物和本机 CurrentUser 受保护发布凭据准备完成后，在仓库根目录显式选择发布动作：

```powershell
pwsh -NoProfile -File .\command\Publish-LanzouMax.ps1 -DryRun
pwsh -NoProfile -File .\command\Publish-LanzouMax.ps1 -Publish
pwsh -NoProfile -File .\command\Publish-LanzouMax.ps1 -VerifyReadback
```

脚本固定读取工作区相对 APK 与 `app_icon.jpg`，通过 `aapt2` 自动取得 `versionName` 并命名为 `LanzouMax<versionName>.apk`。固定图标是 235×235、7,920 字节 JPEG，直接原样调用 `set_icon`，不会从 APK 提取、不调用 `prepare_icon`、不转 PNG、也不重复压缩。简介固定为 `官网链接:https://lanzoumax.nkbr.cc/`。

归档目录只替换与本地版本号相同的旧 APK，其他历史版本保留；软件合集目录替换全部完整匹配的旧 LanzouMax/LanzhouMax APK。两个目录先暂存并回读，任一失败就删除新暂存项、恢复旧项、把恢复到账号根目录的文件移回原目标目录，再按 ID 与名称验证。`-VerifyReadback` 会把两个最终文件下载到 D/H 盘受控临时目录，逐个核对大小和 SHA-256 后清理；未显式选择动作时拒绝执行。

## 安全要求

- 不在源码、配置、文档、测试夹具或日志中保存账号、密码、Cookie、临时签名、私有文件名、分享链接或对象 ID。
- Cookie 只持久化到平台安全存储；登录/恢复期间会短暂经过 FFI 与 Dart/Rust 内存，过期、注销或恢复失败时清理持久状态和 core 会话。
- TLS 证书校验保持开启；只对网络错误、5xx、服务繁忙和挑战页做有限退避。
- 图标绑定与非幂等写入按账号串行；关联状态不明确时先回读，不盲目重放。
- 永久删除与清空回收站必须二次确认，不使用生产数据做破坏性测试。

## 开源许可证

本项目采用 [MIT License](LICENSE)。允许个人与商业使用、修改及再分发；复制或分发本软件及其重要部分时，必须保留原版权声明与许可声明。

版权归 nekobyran 所有，Copyright (c) 2026 nekobyran。

## 协议参考与许可证边界

协议行为固定参考 OpenList commit [`eb48671202247406a451187a8c62fae943acfc3b`](https://github.com/OpenListTeam/OpenList/tree/eb48671202247406a451187a8c62fae943acfc3b/drivers/lanzou)。OpenList 使用 AGPL-3.0；LanzouYOU Rust core 是独立实现，当前不包含 OpenList 源文件。若未来复制、修改、链接或分发其派生代码，必须先评估并履行适用的 AGPL 义务。
