# LanzouLibraryShell：GitHub 源码性能证据

> 调研日期：2026-07-14。本文只记录三个上游仓库当前 HEAD 的可定位源码事实；“适用于 Shell”是基于这些事实对软件库壳场景的落地判断，不把远程桌面或游戏引擎的专用方案伪装成通用优化。

## 1. 固定源码快照

源码以 `--depth 1 --filter=blob:none --sparse` 克隆到 `resource/code/performance-references/`，只检出 Flutter、Android、FFI 与构建相关文件。

| 仓库 | 固定提交 | 本地目录 | 稀疏范围摘要 |
| --- | --- | --- | --- |
| RustDesk | `fa418cace616828c130068260f7c0311b1319ef1` | `resource/code/performance-references/rustdesk` | `flutter/lib`、`flutter/android`、Flutter 构建/依赖文件、`src/flutter*.rs` |
| FlClash | `7c831855efedceb1a72bd0b4c18da026593d0853` | `resource/code/performance-references/FlClash` | `lib`、`android`、`pubspec*`、`setup.dart`、`plugins/rust_api` 的 Dart/Rust/Android 边界 |
| KrKr2-Next | `1abd1ed4e8aec7abd5d2524c3a9ad7886880602f` | `resource/code/performance-references/KrKr2-Next` | Flutter app、Flutter engine bridge、engine API、Android 构建与 ANGLE 平台配置 |

## 2. 可直接用于 Shell 的证据

### 2.1 大列表必须按索引惰性构建

- RustDesk 的设备列表先把展示上限限制为 1000，再由 `ListView.builder` / `DynamicGridView.builder` 按索引生成卡片：[RustDesk `peers_view.dart:235-292`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/flutter/lib/common/widgets/peers_view.dart#L235-L292)。
- FlClash 的代理网格直接以 `currentProxies[index]` 构建 `ProxyCard`，没有先把全部数据映射成 Widget：[FlClash `proxies/tab.dart:327-360`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/views/proxies/tab.dart#L327-L360)。
- KrKr2-Next 的封面库使用 `SliverGrid` + `SliverChildBuilderDelegate`，按可见索引创建封面卡：[KrKr2-Next `home_page.dart:989-1017`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/pages/home_page.dart#L989-L1017)。

**Shell 结论：适用。** 目录、搜索结果和“加载更多”继续使用 `SliverList.builder` / `SliverGrid.builder`，以稳定业务 key 标识条目；不要先 `map<Widget>().toList()` 再交给 builder。RustDesk 的固定 1000 条上限只适合有明确产品上限时采用，不能代替分页。

### 2.2 把高频状态更新限制在最小子树

- FlClash 用 Riverpod `select` 只监听“某测试 URL + 某代理”的延迟值，以及某组当前代理名：[FlClash `state.dart:413-423`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/providers/state.dart#L413-L423)、[`state.dart:480-493`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/providers/state.dart#L480-L493)。
- KrKr2-Next 的打包进度和当前文件名分别由两个 `ValueListenableBuilder` 更新，弹窗其余结构不跟随重建：[KrKr2-Next `home_page.dart:691-727`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/pages/home_page.dart#L691-L727)。
- RustDesk 把重连按钮的可用状态包在单独 `Obx` 中，而不是刷新整个对话框：[RustDesk `common.dart:1283-1300`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/flutter/lib/common.dart#L1283-L1300)。

**Shell 结论：适用，但不要求迁移状态框架。** 保留现有控制器即可；对条目选择、单个图标、下载/描述加载进度使用 selector 或局部 listenable，避免一次 `notifyListeners()` 让导航、搜索框、完整列表和详情面板一起重建。

### 2.3 只隔离真正独立且高频的绘制

- FlClash 的循环波形将 `AnimatedBuilder + CustomPaint` 放入 `RepaintBoundary`，同时在 `dispose` 释放动画控制器：[FlClash `wave.dart:23-59`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/widgets/wave.dart#L23-L59)。
- 同仓库也把持续变化的网络速率卡隔离在 `RepaintBoundary` 内：[FlClash `network_speed.dart:39-50`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/views/dashboard/widgets/network_speed.dart#L39-L50)。

**Shell 结论：条件适用。** 图标、独立进度区、会单独动画的列表条目可作为边界候选；静态文本或每一层容器都加边界会增加 layer 成本，必须用 profile/DevTools 证明后再扩散。稀疏范围精确扫描中，RustDesk 与 KrKr2-Next 的 Flutter 源码均未出现 `RepaintBoundary`，所以不能声称三者都采用了该策略。

### 2.4 图片要同时处理磁盘复用、解码尺寸和资源释放

- FlClash 用单例 `DefaultCacheManager` 拉取图标文件，并在 Widget 更新/销毁时取消旧订阅、释放 `ValueNotifier`：[FlClash `icon.dart:45-124`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/widgets/icon.dart#L45-L124)。但最终 `Image.file` 没有提供 `cacheWidth/cacheHeight`：[FlClash `icon.dart:128-150`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/widgets/icon.dart#L128-L150)。
- RustDesk 的原始像素解码 helper 支持 `targetWidth/targetHeight`，并在成功或异常路径释放 `Codec`、`ImmutableBuffer` 和 `ImageDescriptor`：[RustDesk `image.dart:8-90`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/flutter/lib/utils/image.dart#L8-L90)。该 helper 的抽样调用是远程帧/光标，不是软件图标。
- KrKr2-Next 下载封面时优先缩略图并持久化到本地：[KrKr2-Next `cover_downloader.dart:21-68`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/services/cover_downloader.dart#L21-L68)，但封面列表的 `Image.file` 同样未限制解码尺寸：[KrKr2-Next `home_page.dart:1128-1136`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/pages/home_page.dart#L1128-L1136)。

**Shell 结论：部分适用，并应比上游更严格。** 可借鉴磁盘复用、缩略图优先、取消过期请求和显式释放；软件图标仍应按逻辑尺寸 × DPR 设置有上限的解码尺寸。三个快照都没有展示“远端图标磁盘缓存 + Widget 解码尺寸约束”的完整组合，不能直接照抄任何一个实现。

### 2.5 动画必须有因果、生命周期和停表策略

- FlClash 的页面交叉切换在底层页面不再可见时用 `TickerMode` 关闭其 ticker，只在过渡期临时开启：[FlClash `animated_cross_slide.dart:192-242`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/widgets/animated_cross_slide.dart#L192-L242)；控制器也在 `dispose` 中释放：[同文件 `102-163`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/widgets/animated_cross_slide.dart#L102-L163)。
- FlClash 的启动按钮只在真实启停状态变化时播放 200ms 动画，并释放控制器：[FlClash `start_button.dart:15-67`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/views/dashboard/widgets/start_button.dart#L15-L67)。
- KrKr2-Next 的游戏循环用 vsync `Ticker`，用 `_tickInFlight` 防止异步帧重入，并在停止时 `stop + dispose`：[KrKr2-Next `game_page.dart:465-489`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/pages/game_page.dart#L465-L489)、[`game_page.dart:537-549`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/pages/game_page.dart#L537-L549)。

**Shell 结论：生命周期原则适用，游戏帧循环不适用。** Shell 的页面/列表状态动效应由真实状态触发、控制器必释放、不可见页面停表；不应引入常驻 Ticker。三个快照的调研范围均未找到 `MediaQuery.disableAnimations` 或 `accessibleNavigation` 的动效降级实现，因此 Shell 自己的“减少动态效果”路径不能删，也不能把上游当作无障碍动效范本。

### 2.6 重工作业离开 UI 帧，并防止异步重入

- FlClash 用 Flutter `compute` 执行目录扫描，并以 `RootIsolateToken` 初始化后台 isolate 的平台消息能力：[FlClash `task.dart:274-319`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/lib/common/task.dart#L274-L319)。
- FlClash 的 Rust IPC API 向 Dart 暴露 `Stream` / `Future`：[FlClash `ipc.dart:12-24`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/plugins/rust_api/lib/src/rust/api/ipc.dart#L12-L24)，Rust 侧把阻塞 I/O 放到命名线程 `ipc-server`：[FlClash `ipc.rs:67-112`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/plugins/rust_api/rust/src/api/ipc.rs#L67-L112)。
- KrKr2-Next 的 C API 明确说明异步打开会在后台 worker 排队并立即返回：[KrKr2-Next `engine_api.h:171-184`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/bridge/engine_api/include/engine_api.h#L171-L184)，实现确实创建 `std::thread`：[KrKr2-Next `engine_api.cpp:874-955`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/bridge/engine_api/src/engine_api.cpp#L874-L955)。

**Shell 结论：适用。** 网络解析、聚合排序、大 JSON/HTML 解析和批量图标处理不得阻塞 Flutter 帧；高频刷新与轮询需使用 in-flight guard、请求代次或取消机制。不要只因 Dart 方法返回 `Future` 就认为同步 FFI 已离开 UI isolate；必须像上述 C/Rust 实现一样能定位到真正的 worker/isolate。

## 3. Renderer / Impeller / ANGLE：必须排除的错误类比

- RustDesk 的 Flutter 依赖包含 RGBA/GPU texture renderer：[RustDesk `pubspec.yaml:88-97`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/flutter/pubspec.yaml#L88-L97)，但 Rust 侧明确把 texture 路径放在非 Android/iOS 分支，移动端回到软件 RGBA 路径：[RustDesk `flutter.rs:862-885`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/src/flutter.rs#L862-L885)。这是远程桌面帧传输方案，不是普通列表 UI 优化。
- KrKr2-Next 的 ANGLE 配置明确使用自己的 EGL，以避免与使用系统 EGL 的 Flutter Impeller 冲突，并为游戏引擎提供 GLES/Vulkan backend：[KrKr2-Next `PlatformAndroid.cmake:2-7`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/vcpkg/ports/angle/cmake-buildsystem/PlatformAndroid.cmake#L2-L7)。Flutter 设置页保存的 renderer/ANGLE 值也在打开游戏前传给 engine option：[KrKr2-Next `game_page.dart:377-396`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/lib/pages/game_page.dart#L377-L396)。这不是切换 Flutter 自身渲染器。
- 在本次稀疏范围内，RustDesk 和 FlClash 对 `Impeller|ANGLE` 的精确扫描结果均为 0；两者 Android manifest 只显式启用常规硬件加速：[RustDesk `AndroidManifest.xml:60-67`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/flutter/android/app/src/main/AndroidManifest.xml#L60-L67)、[FlClash `AndroidManifest.xml:29-45`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/android/app/src/main/AndroidManifest.xml#L29-L45)。

**Shell 结论：不要引入 ANGLE、远程帧 texture plugin 或自定义游戏 renderer。** 保持 Flutter 默认渲染路径，Android/Windows 分别用 profile 真机测量；只有出现可复现的驱动/渲染缺陷并有目标设备证据时，才讨论 renderer override。

## 4. Release / Profile 构建事实

- RustDesk Android 脚本默认 release，并启用 `--obfuscate`、`--split-debug-info`、`--split-per-abi`：[RustDesk `build_android.sh:3-7`](https://github.com/rustdesk/rustdesk/blob/fa418cace616828c130068260f7c0311b1319ef1/flutter/build_android.sh#L3-L7)。
- FlClash release 开启 R8 minify 与资源 shrink：[FlClash `build.gradle.kts:63-82`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/android/app/build.gradle.kts#L63-L82)，打包器对 Android 加入 `split-per-abi`：[FlClash `setup.dart:100-111`](https://github.com/chen08209/FlClash/blob/7c831855efedceb1a72bd0b4c18da026593d0853/setup.dart#L100-L111)。
- KrKr2-Next release 同样开启 minify/shrink，但只保留 `arm64-v8a` 是为了 ANGLE/vcpkg 游戏引擎：[KrKr2-Next `build.gradle.kts:32-41`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/android/app/build.gradle.kts#L32-L41)、[`build.gradle.kts:69-80`](https://github.com/reAAAq/KrKr2-Next/blob/1abd1ed4e8aec7abd5d2524c3a9ad7886880602f/apps/flutter_app/android/app/build.gradle.kts#L69-L80)。

**Shell 结论：** minify/shrink、符号分离和按 ABI 分包主要是体积与发布策略，不能作为“运行更流畅”的证据；Shell 不应照抄 KrKr2-Next 的 arm64-only 限制。三个快照的稀疏构建范围均未提供可复现的 Flutter profile benchmark、帧时间阈值或自动回归门禁，因此性能验收仍需 Shell 自己在 Android/Windows profile 下记录 build/raster 帧、内存和滚动行为。

## 5. Shell 落地优先级

1. **P0：** 保证目录/搜索惰性 Sliver、稳定 key、分页，禁止预创建整批 Widget。
2. **P0：** 将解析/聚合/批处理放到 Rust worker 或 Dart isolate；所有可能重入的刷新使用请求代次、取消或 in-flight guard。
3. **P0：** 图标使用有界下载缓存与按 DPR 限制的解码尺寸；旧请求、订阅、`ui.Image`/codec 必须释放。
4. **P1：** 高频局部状态使用 selector/listenable；`RepaintBoundary` 只包经 profile 证明独立重绘的区域。
5. **P1：** 动画保持短、因果明确、不可见即停，并保留系统“减少动态效果”降级；不新增常驻装饰性 ticker。
6. **拒绝项：** 不把 RustDesk texture renderer、KrKr2-Next ANGLE/Vulkan 游戏管线或 arm64-only 构建复制到 LanzouLibraryShell。

## 6. 正式 Android 模板构建门禁

`command/Build-LanzouLibraryTemplates.ps1` 的 Android 路径固定调用 `flutter build apk --release --target-platform android-arm64,android-x64`，并在模板发布前检查 APK 本体，而不是只检查构建命令：

- 两个 ABI 都必须包含 AOT `libapp.so`、Flutter engine `libflutter.so` 与 release Rust core；实际 native ABI 集合必须恰好是 `arm64-v8a`、`x86_64`。
- 禁止 debug/JIT 的 `kernel_blob.bin`、VM/isolate snapshot 与 Vulkan validation layer，最终 Manifest 必须 non-debuggable。
- application 与主 Activity 必须保持硬件加速，native library 必须非压缩且 `extractNativeLibs=false`，最终 APK 必须通过 16 KiB `zipalign` 校验。
- Manifest 不允许偷偷写入 Impeller/Vulkan renderer override；保持 Flutter 默认 renderer，等待目标设备 profile 证据，而不是复制游戏引擎或远程桌面专用管线。

脚本 `-SelfTest` 用最小 APK 夹具同时证明 release/AOT 布局可通过、带 `kernel_blob.bin` 的 debug/JIT 布局会被拒绝。

## 7. Android Profile 实测与正式真实源证据边界

### 7.1 本地 1000 项 Profile 压测

匿名证据固定在 `verification/performance/shell-android-profile-20260714-112127/`：

- `metrics.json`：Flutter FrameTiming、启动、CPU、PSS、renderer、工作负载与清理状态的可机读结果。
- `summary.md`：指标口径、结论与适用边界。
- `profile-run.log`：Profile 构建、ADB 旁证、阈值门禁及清理结果的匿名运行摘要。

测试只操作本地 MuMu，使用 `--no-dds --profile` 运行 testHarness。负载为一个 1000 项惰性双列目录；每项使用唯一的 HTTPS 占位图标路径，由测试 core 返回同一份合法小 PNG，覆盖 `FutureBuilder`、有界请求队列与按 DPR 解码路径，但不联网、不读取正式源，也不记录任何真实链接或源标识。可见惰性条目由索引 `0–3` 移动到 `198–203`，完成 10 次长滑动并触发 208 次本地图标请求。

| 指标 | 实测结果 |
| --- | ---: |
| Flutter FrameTiming | 368 帧 |
| Jank | 0 帧 / 0% |
| P50 / P90 / P95 / P99 | 0.976 / 1.484 / 1.656 / 1.986 ms |
| UI / Raster 预算超限 | 0 / 0 |
| Profile 冷启动 `TotalTime` | 1836 ms |
| CPU | 单核等效 44.536%；设备归一 11.134% |
| Total PSS | 143248 KB |
| Renderer | Impeller Vulkan |

帧耗时统一定义为每帧 `max(buildDuration, rasterDuration)`。机器门禁要求采样不少于 120 帧、P95 不高于 24 ms、P99 不高于 50 ms，且 UI/Raster 各自的 16 ms 预算超限率不高于 10%；本次全部通过。Android host `gfxinfo` 与 SurfaceFlinger 只作旁证，最终滚动结论以 Flutter FrameTiming 为准。

### 7.2 两条证据不能互相替代

1. **Profile testHarness 性能证据**证明 Material 3 Shell 在确定性的 1000 项压力负载下保持 Sliver 惰性构建、异步图标处理和低帧耗时；它不经过正式 `lib/main.dart`、嵌入配置或真实源 Rust 解析，不能证明生产数据链路可用。
2. **正式 real-source Release smoke**单独保存在 `verification/real-source-shell/` 的受限运行目录中；文档刻意不索引带源标识的运行子目录。其匿名结果证明 production 入口、真实源 browse、图标获取、HTTPS 下载解析和 Release UI 目录均成功，进程存活且 fatal 为 0；它是功能/集成证据，不是 1000 项性能基准。

因此，性能结论必须引用本节的匿名 Profile 目录；正式链路结论必须引用 `verification/real-source-shell/` 下对应的 `runtime-core-probe.json`、`runtime-ui-smoke.json` 与 `artifacts-manifest.json`。任何一条通过都不得推导另一条也通过。
