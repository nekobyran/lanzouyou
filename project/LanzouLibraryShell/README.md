# LanzouLibraryShell

LanzouLibraryShell 是 LanzouYOU 的可配置软件库成品壳。Android 与 Windows 共用 Flutter Material 3 界面，公开蓝奏目录浏览、跨源搜索、结果聚合、资源获取和真实本地下载统一调用 Rust shared core。

它不是网盘管理客户端：成品壳不提供管理端登录、上传、改名或删除能力，也不会共享 LanzouYOU 管理会话。

## 运行时配置

成品只读取以下两个固定资源：

- `assets/runtime/library.json`：`schemaVersion: 1` 的软件库配置
- `assets/runtime/logo.png`：软件库品牌图标

canonical 配置结构如下：

| 区域 | 字段 |
|---|---|
| `identity` | `projectId`、`displayName`、`applicationId`、`versionName`、`versionCode`、`windowsExeName` |
| `branding` | `seedColor`、`officialUrl`、`publisher`、固定的 `logoAsset`、`themeMode` |
| `sources[]` | `sourceId`、`title`、`shareUrl`、`password`、`searchable`、`recommended` |
| `features` | `browse`、`search`、`download`、`showDescription` |

`sources` 必须包含 1–512 个软件源，可完整容纳当前 LanzouMax 的 474 源目录；生成器、命令行重打包、Rust 核心和成品壳使用同一上限。`logoAsset` 固定为 `assets/runtime/logo.png`。访问码只用于访问相应公开分享，不进入公开模型、界面、错误信息或日志；但它会随运行时配置封装进最终产物，因此不能被当作不可提取的秘密。

### 正式入口与无假源边界

正式 Android APK 与 Windows 程序固定从 `lib/main.dart` 启动，并且只有一条运行链路：

1. `LibraryConfigLoader.embeddedRuntime()` 从 `rootBundle` 读取固定的 `assets/runtime/library.json`；
2. 配置严格通过 canonical `schemaVersion: 1` 校验后，交给 `LibraryShellApp.production(config: ...)`；
3. `production` 只创建一份 `RustLibraryCore.production()`；当且仅当 `features.download=true` 时再用同一 core 创建真实 `DownloadCoordinator.production(...)`。有界长驻 isolate worker 组通过 FFI 调用随产物打包的 Rust shared core，UI isolate 永不直接同步调用 FFI。

正式 transport 固定为 1 个操作控制 worker 与 3 个通用 worker。每个 worker 只在启动时打开一次 DLL/SO 并解析一次 `lanzouyou_dispatch`/`lanzouyou_free`，之后以 request id 路由并串行执行本 worker 的 native 请求；通用请求按当前负载复用 worker，`operation_status`、`operation_cancel`、`operation_forget` 始终走独立 control worker，因此长时间运行的同步 `library_search` 不会阻塞真实进度与取消。单 worker 异常会安全失败其 pending 请求，后续最多自动重启一次，禁止无限创建 isolate；应用控制器销毁时先取消活动操作，再关闭 worker 组并失败所有未完成请求。

源码模板自带的 `library.json` 不是演示软件源，而是只有 `schemaVersion: 0` 与 `templateState: requiresGeneration` 的“尚未生成”哨兵。直接运行未重打包模板只会显示明确的生成提示，不会访问任何默认、示例或回退源；只有 LanzouYOU/离线 recipe 重打包成功后，才会把它替换为经过校验的 `schemaVersion: 1` 配置。

`LibraryShellApp.testHarness(...)`、`LibraryConfigLoader.testHarness(...)`、`RustLibraryCore.testHarness(...)` 只允许测试显式注入依赖。`tool/library_shell_preview.dart` 也是独立的本地视觉验收入口，并在 release 模式主动拒绝运行。维护者模板构建使用默认 `lib/main.dart`，不会把 preview、测试 core 或 test harness 数据编入正式 release。

## Material 3 自适应界面与性能边界

Android 与 Windows 共用同一套 Flutter Material 3 widget tree，不维护平行平台页面：

- `390 px` 紧凑布局提供真正的品牌首页：居中显示运行时 logo/`displayName`，首页搜索直接调用真实跨源搜索，软件源入口完全来自运行时配置；底部 `NavigationBar` 固定提供“首页”和“目录”，并在 `features.download=true` 时增加同级“下载”目的地；
- 紧凑“目录”先显示真实软件源总览，进入来源后显示路径、来源标题、远端返回的发布者/简介、已加载项目数、全局搜索与刷新；文件和来源总览均使用无 Card 的两列惰性信息流；
- `768 px` 中等布局使用 88 px 自绘惰性来源窗格与单栏目录；来源由单一 `ListView.builder` 按视口创建，启用下载时窗格底部固定提供同级“下载”目的地；
- `1440 px` 扩展布局把自绘惰性来源窗格展开到 280 px，目录作为主区，文件详情作为独立从区；启用下载时窗格底部同样固定“下载”目的地；实际断点为 `<720`、`720-1199`、`>=1200`；
- 搜索、主操作和次级操作分别使用 `SearchBar`、`FilledButton`、tonal/outlined/icon 按钮。普通目录和文件使用直接列表流、分隔线与 selected/hover/focus/pressed state layer，不把每个条目包装成卡片。

下载不是浏览器跳转：文件操作提交到单活动任务 FIFO，Rust 执行 `library_download` 的真实解析与落盘，`operation_status` 提供真实字节进度，`operation_cancel` 协作取消。下载页显示平台实际 Downloads 保存路径以及排队、解析、下载、取消中、成功、失败、已取消状态；成功项可调用系统打开，失败/取消项可从原条目重试。Windows 直接调用 `ShellExecuteW`，把 UTF-16 文件路径作为独立参数交给已注册的系统关联应用，不经过命令解释器，因此合法文件名中的元字符不会被解释；Android 仍由 `open_filex` 把 APK 交给系统安装器。访问码只存在于当前内存队列，请求结束即清除，不会写入历史。

下载历史以原子 JSON 保存在应用支持目录的 `data/history/downloads.json`，启动时把未完成记录标记为中断失败。最终文件只写入平台 Downloads 目录；传输先写同目录隐藏 `.part`，成功后以不覆盖语义原子发布，同名文件存在、取消、失败或 15 秒没有收到新数据时都会安全失败并清理临时文件。队列严格单活动、按加入顺序执行；高频字节进度只重建对应下载行与动作区域，不重建应用壳、目录或整张历史列表。

所有可见状态变化共用 `AppMotion`：加载到内容、空态、错误、搜索取消、源/目录切换、行选择、详情切换和“加载更多”插入都有因果明确的过渡。检测到 `MediaQuery.disableAnimations` 或 `accessibleNavigation` 时，过渡立即完成，循环加载动画改为静态状态图标；状态仍由文案、图标和语义表达，不依赖动画本身。Windows 支持 hover、可见键盘焦点、`Ctrl+F`、`F5` 与 `Escape`，Android 保留至少 48 dp 操作目标、系统返回和原生滚动行为。

中宽布局目录使用 `SliverList.builder`，紧凑文件流与来源总览使用 `SliverGrid.builder`，均按视口惰性创建且不保留退出页面的整棵列表。控制器不再挂在应用根部 `AnimatedBuilder` 上：返回拦截、AppBar、惰性来源窗格、内容、搜索进度和详情分别按不可变投影局部监听；搜索进度/取消拥有独立 selector，高频轮询不会重建 breadcrumb、来源头、搜索框或目录，未变化轮询还会从 160 ms 逐步退避到 400 ms。Sliver 使用框架自身的自动 repaint boundary，不再为每项重复创建 layer。加载更多期间保留同一个 Scrollable 与视口偏移；一次追加最多只为前 8 个新行创建入场动画，并记录已播放条目，离开再回到视口不会重播。远程图标只为可见行按目标尺寸加载，内存解码边长上限为 192 物理像素，控制器的资产 future 缓存上限为 64 项，同时最多执行 6 个请求、等待 32 个请求，图标完成只刷新对应 `FutureBuilder`。1000 项两列目录在首屏及滚动后实际构建均少于 30 项且无布局溢出。

## Rust 公开软件库接口

软件库壳通过 `lanzouyou_dispatch` / `lanzouyou_free` 调用八个公开软件库操作：

| `op` | 用途 |
|---|---|
| `library_probe` | 探测并校验单个软件源 |
| `library_browse` | 分页浏览目录或文件列表 |
| `library_search` | 在启用搜索的软件源之间执行受限并发搜索；可传 `operationId` 取得按源进度并协作取消 |
| `library_collect` | 补全并归一化选中的跨源结果 |
| `library_resolve` | 解析单个文件的最终下载信息 |
| `library_download` | 解析并把单个公开文件真实写入指定绝对目录；可传 `operationId` 取得 `kind=download` 的真实字节进度并协作取消，成功返回 `{path,fileName,bytesWritten}` |
| `library_describe` | 选中文件时按需读取分享页简介 |
| `library_fetch_asset` | 由 Rust 受控获取、校验并转码远程图标 |

搜索与本地下载另外使用三个共享控制操作：`operation_status {operationId}`、`operation_cancel {operationId}`、`operation_forget {operationId}`。控制请求不等待公开软件库长操作释放锁；搜索页持续显示已完成源数与已发现结果数，下载页持续显示真实传输字节并允许在运行中请求取消；两者都只在 `succeeded/cancelled/failed` 终态后清理注册项。注册表上限为 128 项。

Rust 解析器已同步当前 LanzouMax 目录策略：源探测始终比较 Android/Desktop UA，按可用项目数与耗时记住更好的目录路径；minimal/classic/reflow/unknown 模板使用分离的首页/后续页节流，`zt=4` 退避只影响当前 UA 与页阶段且最多 8400 ms。取消分享会返回稳定安全错误；旧 Lanzou 域名写法只被规范到可信 `www.lanzouw.com` 路径，不放宽网络白名单。搜索 API 是快速路径，随后仍会用有界 BFS 补全目录树并去重；源偏好缓存同样为 512 项上限。

这些操作使用与管理端 Cookie 隔离的公共会话。普通软件源只接受 `lanzouw.com`、`lanzoui.com` 及其普通 ASCII 子域，拒绝 URL 凭据、尾点、IDN 和任何显式端口；`library_resolve` 与 `library_download` 的二次验证 bootstrap 才能进入同一受信 `*.dmpdmp.com` origin 的 HTTPS `/file` 范围，每个重定向和 Ajax 端点都会重新校验路径。精确受信的蓝奏与 `dmpdmp.com` 下载主机兼容代理/TUN 提供的 `198.18.0.0/15` fake-IP；其他直链主机仍须只解析到公网地址，IP 字面量仍拒绝私网、回环与保留地址。`library_download` 只接受绝对目标目录路径，路径缺失时创建目录、已存在时必须确为目录；它不返回最终直链，不覆盖同名文件，并对传输流实施 15 秒读取空闲超时。`library_describe` 的响应正文上限为 2 MiB，简介上限为 8192 字符。远程图标不再由 Flutter `Image.network` 直连；`library_fetch_asset` 仅接收 `image.dmpdmp.com`，以及 `images.bakstotre.com/assets/images/type/` 路径，逐跳阻断跨 origin、HTTP 与私网地址，输入最多 1 MiB，解码、缩放后固定返回严格 `{"mediaType":"image/png","bytesBase64":"..."}`，再由 Flutter 以内存 PNG 渲染。输出统一使用 camelCase，条目保留 `sourceId`，且不得包含访问码或 Cookie；携带访问码时的远端错误固定为安全文案。

## 离线模板重打包

LanzouYOU 的“生成软件库”功能不是在手机或电脑上重新编译本工程，而是修改已预构建的模板：

- `library_repackage_android`：替换 APK 内的运行时配置和图标，修改应用标识、名称与版本，并用本机稳定签名身份生成 Android APK。
- `library_repackage_windows`：替换便携版中的运行时配置和图标，修改 Windows EXE 品牌/版本信息与文件名，再生成 Windows x64 ZIP。

因此，**Android 版 LanzouYOU 也能生成 Windows x64 便携 ZIP**。它只是重打包随应用提供的 Windows 模板，不是在 Android 上编译 Windows 可执行文件，也不会生成传统 Windows 安装程序。

最终用户生成过程有以下固定边界：

- 不下载模板或构建工具；
- 不调用 Flutter、Gradle、Cargo 或远程构建服务；
- 不修改模板原件，不覆盖已存在的输出；模板由同一 `schemaVersion: 2` generation manifest 绑定，且必须恰好包含 Android、Windows 两个固定目标与两份产物，并校验 generation `runId`、实际文件大小/SHA-256、core ABI 版本与两个固定导出符号、recipe schema；LanzouYOU 只有在整代模板全部验证通过后才返回任一模板；
- Android APK 使用 v2 签名，模板最低支持 Android API 24；同一应用标识后续升级依赖同一签名身份；
- Windows 输出是便携 ZIP，EXE 不带商业代码签名，首次运行仍可能触发系统信誉提示。

## 两类脚本

在仓库根目录运行。维护者预构建模板：

```powershell
pwsh -NoProfile -File .\command\Build-LanzouLibraryTemplates.ps1
```

该脚本只用于维护期，会调用 Flutter/Cargo 生成 Android 和 Windows 壳模板，在同一 staging generation 完成结构、`schemaVersion: 2` manifest 与摘要校验后，才原子切换 LanzouYOU 的整代内置资源。任一目标失败都保留上一代完整模板。维护者 release 只保留 `release/generations/<runId>/` 不可变证据，成功发布后删除 release 根层三个旧兼容入口而不触碰历史代。它不是最终用户生成入口。

已有 recipe 的离线重打包入口：

```powershell
pwsh -NoProfile -File .\command\Build-CustomLanzouLibrary.ps1 -RecipePath .\recipe.json
```

该脚本只读取本地 recipe、同代 `schemaVersion: 2` manifest 约束的预构建模板和固定 Rust core，不调用 Flutter、Gradle、Cargo，也不联网下载。多目标会先全部生成并验证，再以单一目录原子发布。日常图形化生成应直接从 LanzouYOU 文件夹菜单进入“生成软件库”；图形界面选择双目标时只提交一次文件保存，得到内含 APK、Windows ZIP 与去密清单的原子完整包。生成页支持主动取消；当前目标完成后不再开始下一目标或导出，主动取消与保存窗口取消都按“已取消”处理并清理临时作业。

## 维护者构建

源码构建前设置 `LANZOUYOU_CORE_DIR` 为 LanzouYOU `lanzouyou_core` crate 目录。Windows CMake 会构建并随程序放置 `lanzouyou_core.dll`；Android Gradle 会为 `arm64-v8a` 与 `x86_64` 构建并打包 `liblanzouyou_core.so`。

模板、recipe 与 FFI 的完整契约见 [LanzouYOU 架构与 API 状态](../../docs/lanzouyou-api.md)。

当前软件库壳 102 项 Flutter 测试全部通过，覆盖 390/768/1440 自适应布局、紧凑首页→来源→目录、真实全局搜索、`features.download` 导航门控、单活 FIFO、真实字节进度、取消/重试/系统关联打开、含元字符文件名的 Windows 安全传参、实际保存路径、原子历史恢复、下载行局部重建、两列 1000 项惰性 grid、常驻 worker 复用/request id 路由/control 旁路/有界崩溃恢复与关闭、Material 3 语义、严格状态动画、reduced motion、键盘与返回；共用 Rust core 为 35 个 `op`（22 个账号管理、8 个公开软件库、2 个离线重打包、3 个操作控制），当前 185 项单元测试与 6 项 dispatch contract 测试通过。
