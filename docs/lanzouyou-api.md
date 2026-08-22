# LanzouYOU 架构、FFI 与 Woozooo 协议状态

> 本文只记录接口形状、实现状态和无敏感计数。不得在文档、日志、测试夹具或错误信息中写入账号、密码、Cookie、临时签名、私有文件名、分享链接或对象 ID。

## 1. 工程边界

LanzouYOU 是 Windows 与 Android 共用的 Flutter 客户端，确定性网络协议、解析、校验和文件传输由 Rust shared core 提供。

```text
Flutter Material 3 UI
  ├─ controllers / CloudService
  ├─ flutter_secure_storage（只保存会话 Cookie）
  └─ persistent Dart worker isolate
       └─ C ABI：lanzouyou_dispatch / lanzouyou_free
            └─ Rust：session / parser / transfer / HTTP / acw_sc__v2
                 └─ Woozooo Web 私有协议
```

- Flutter 源码：`project/LanzouYOU/lib/`
- Rust core：`project/LanzouYOU/native/lanzouyou_core/`
- Dart FFI 适配：`project/LanzouYOU/lib/services/rust_cloud_service.dart`
- Rust dispatch：`project/LanzouYOU/native/lanzouyou_core/src/dispatch.rs`
- Rust 公开软件库解析与模板重打包：`project/LanzouYOU/native/lanzouyou_core/src/library/`
- Rust 内置目录资产：`project/LanzouYOU/native/lanzouyou_core/assets/catalog/{s,h,c}`；由 `library/catalog.rs` 通过 `include_bytes!` 打包并在 Rust 内建索引
- LanzouYOU 真实公共软件库页：`project/LanzouYOU/lib/pages/public_library/`
- LanzouYOU 自定义软件库生成页：`project/LanzouYOU/lib/pages/library_builder/`
- Flutter 软件库成品壳：`project/LanzouLibraryShell/`
- 统一构建入口：`command/Invoke-FlutterClient.ps1`（`Invoke-LanzouYOU.ps1` 仅保留为轻量转发名）
- 维护者模板构建：`command/Build-LanzouLibraryTemplates.ps1`
- 最终用户本地重打包：`command/Build-CustomLanzouLibrary.ps1`
- Windows 字体策略：`project/LanzouYOU/lib/shared/app_theme.dart` 保留平台主字体 Segoe UI，并按 `Microsoft YaHei UI → Microsoft YaHei → Segoe UI Symbol` 显式回退；Android 不注入 Windows 字体

Rust C ABI 是同步接口；正式 Flutter 图通过 `PersistentIsolateJsonCoreTransport` 复用一个长驻 worker isolate，账号操作与公共 catalog 共享同一 native runtime，不在每次请求时新建 isolate，也不在 UI isolate 做协议解析。账号管理数据操作由互斥会话锁串行，公开软件库操作使用独立会话和有界全局执行器并可并行；三个操作控制直接访问注册表，不等待上述长操作。

公开软件库解析使用独立的无管理 Cookie 会话，不读取或修改账号管理会话。两个模板重打包操作只访问调用方明确给出的本地模板、配置、图标、签名身份和输出路径，不发起网络请求。

字体策略遵循 Flutter [`TextStyle.fontFamilyFallback`](https://api.flutter.dev/flutter/painting/TextStyle/fontFamilyFallback.html) 的有序查找语义；Microsoft 的 [Windows Typography](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/typography) 把 Microsoft YaHei UI 列为简体中文 UI 字体。主题只在 `TargetPlatform.windows` 设置该回退链，避免 Android 被强制套用 Windows 字体。

## 2. FFI 契约

Rust 只导出两个 C ABI 符号：

```c
char *lanzouyou_dispatch(const char *request_json);
void lanzouyou_free(char *response_json);
```

- 请求和响应均为 UTF-8 JSON。
- `lanzouyou_dispatch` 返回 Rust 分配的字符串；调用方必须且只能调用一次 `lanzouyou_free`。
- Rust panic、空指针、非 UTF-8、未知 `op` 和解析失败都转换为统一错误 envelope，不穿过 FFI 边界。

成功响应：

```json
{"ok":true,"data":{},"error":null}
```

失败响应：

```json
{"ok":false,"data":null,"error":{"code":"error_code","message":"安全错误信息","retriable":false}}
```

`error.retriable` 只表示调用方可以在退避后重新尝试，不表示允许无限重试。`session_expired` 会清空 Rust 内存会话，并由 Flutter 删除安全存储中的旧 Cookie。

## 3. Dispatch `op`

字段采用 `op` 的 snake_case 与其余字段的 camelCase。目录根 ID 默认由 core 内部设为 `-1`，调用方不应自行猜测其他根值。

| `op` | 请求字段 | 当前 Rust 落点 |
|---|---|---|
| `login` | `account`, `password` | 账号登录并初始化会话 |
| `restore_session` | `cookie` | 校验并恢复安全存储中的会话 |
| `logout` | 无 | 注销并清空内存会话 |
| `session_info` | 无 | 返回非敏感会话状态，不返回 Cookie |
| `list` | `folderId`, `page`, `pageSize` | 合并目录与文件分页 |
| `move_targets` | 无 | 读取移动目标目录 |
| `mkdir` | `parentId`, `name`, `description` | 新建目录 |
| `rename` | `id`, `isFolder`, `name` | 文件或目录改名 |
| `move` | `id`, `isFolder`, `targetId` | 文件移动；目录使用受限递归流程 |
| `delete` | `id`, `isFolder` | 移入回收站 |
| `share_info` | `id`, `isFolder` | 分享信息；文件同时解析下载直链 |
| `get_description` | `id`, `isFolder` | 读取当前账号项的简介 |
| `account_capabilities` | 无 | 使用当前会话只读获取 `profile/mypower` 与 `profile/huiyuan`，返回会员三态、到期日、9 个个人入口、8 项账号事实、实时套餐候选和 11 项个性化能力；不返回 Cookie/HTML，也不接收付款数据 |
| `set_password` | `id`, `isFolder`, `password` | 设置或清除提取码 |
| `set_description` | `id`, `isFolder`, `description` | 设置简介 |
| `upload` | `folderId`, `path`, `compatWrap`, `kind`, `operationId`（可选） | 普通文件上传；`kind` 仅为 `auto/file`，可报告字节进度并协作取消 |
| `prepare_icon` | `sourcePath`, `outputPath`（可选） | 解码图片或提取 APK launcher，生成严格小于 100,000 字节的 PNG |
| `set_icon` | `fileId`, `path` | 使用真实 Woozooo 图标协议把本地图片关联到文件 |
| `replace_file` | `oldFileId`, `folderId`, `path`, `compatWrap`, `iconPath`（可选）, `operationId`（可选） | 先上传/图标处理并回读，再替换旧文件；失败时按 Rust 状态机回滚可回滚步骤 |
| `download` | `id`, `name`, `destination`, `operationId`（可选） | 解析直链、下载并按需还原兼容包；可报告字节进度并协作取消 |
| `copy` | `id`, `isFolder`, `name`, `targetId`, `tempDir` | 下载后重新上传的递归复制 |
| `recycle_list` | 无 | 读取回收站 HTML |
| `recycle_restore` | `id`, `isFolder` | 恢复回收站项目 |
| `recycle_purge` | `id`, `isFolder` | 永久删除单项 |
| `recycle_empty` | 无 | 清空回收站 |
| `operation_status` | `operationId` | 读取上传、下载或跨源搜索的固定进度状态 |
| `operation_cancel` | `operationId` | 请求运行中的操作协作取消并返回最新状态 |
| `operation_forget` | `operationId` | 从有界注册表清理已经进入终态的操作 |
| `catalog_summary` | 无 | 从 Rust 打包资产返回 revision、官方源/合集/节点/可搜索数 |
| `catalog_page` | `parentId`, `categoryId`, `query`, `cursor`, `limit` | 在 Rust 索引中筛选并分批返回目录节点；游标与查询条件绑定 |
| `catalog_browse` | `nodeId` 或无密码 `itemRef`, `page`, `refresh` | 在 Rust 内查找分享链接/访问码并真实浏览列表、文件夹或单软件节点 |
| `catalog_search` | `query`, `scopeIds`, `options`, `operationId`（可选） | Rust 内展开选中源/合集、合并本地成员并执行有界跨源搜索 |
| `catalog_describe` | `nodeId` 或无密码 `itemRef` | Rust 内查找访问码并按需读取简介 |
| `catalog_resolve` | `nodeId` 或无密码 `itemRef` | Rust 内查找访问码并解析文件下载信息 |
| `catalog_download` | `nodeId` 或无密码 `itemRef`, `destinationDirectory`, `operationId`（可选） | Rust 内查找访问码，解析并真实原子落盘 |
| `library_probe` | `source` | 校验一个公开蓝奏软件源并读取根信息 |
| `library_browse` | `sourceId`, `shareUrl`, `password`, `page`, `refresh` | 分页浏览公开目录；访问码只作为输入 |
| `library_search` | `query`, `sources`, `options`, `operationId`（可选） | 在多个启用源之间执行有界搜索；按源/页报告进度并协作取消 |
| `library_collect` | `items`, `sources` | 补全、去重并归一化跨源结果 |
| `library_resolve` | `sourceId`, `shareUrl`, `password` | 解析单个公开文件的最终下载信息 |
| `library_download` | `sourceId`, `shareUrl`, `password`, `destinationDirectory`, `operationId`（可选） | 解析并真实写入本地文件；成功返回 `{path,fileName,bytesWritten}`，携带 `operationId` 时注册为 `kind=download` |
| `library_describe` | `sourceId`, `shareUrl`, `password` | 选中文件时按需读取分享页简介，返回 `{description}` |
| `library_fetch_asset` | `url` | 逐跳校验并获取可信远程图标，缩放转码后固定返回严格 `{"mediaType":"image/png","bytesBase64":"..."}` |
| `library_repackage_android` | `templatePath`, `outputPath`, `runtimeConfig`, `iconPath`（可选）, `signingIdentityPath` | 离线修改预构建壳 APK 并执行 APK v2 签名 |
| `library_repackage_windows` | `templatePath`, `outputPath`, `runtimeConfig`, `iconPath`（可选） | 离线修改预构建 Windows x64 便携模板并输出 ZIP |

当前 Rust `Command` 枚举合计 **45 个操作**：25 个账号/文件管理操作、7 个内置 catalog 操作、8 个低层公开软件库操作、2 个离线模板重打包操作和 3 个操作控制。任何一侧新增、删除或改名 `op` 都必须同步更新调用方和契约测试。

> 验证状态：上述是当前源码契约，不是本轮最终门禁通过声明。Rust/Flutter 测试数只在父任务完成实际全量命令后由 verification 证据记录，不在实施中文档预写通过数。

注意：`kind=icon` 已从上传 schema 删除。文件自定义图标必须使用 `set_icon`，需要提取、改格式或压缩时先调用 `prepare_icon`；已经满足格式和大小要求的本地图片可直接交给 `set_icon`。Flutter 不会再把图标作为独立云文件上传。

### 操作控制响应边界

- `upload`、`replace_file`、`download`、`library_download`、`library_search`、`catalog_download` 和 `catalog_search` 只在请求携带 `operationId` 时注册为可控操作；标识必须是 1–64 位 ASCII 字母、数字、点、下划线或连字符。
- `operation_status` 与 `operation_cancel` 固定返回 `operationId`、`kind`、`state`、`completedUnits`、`totalUnits`、`bytesTransferred`、`totalBytes`、`itemsFound`。`kind` 只能是 `upload/download/library_search`，`state` 只能是 `running/cancelling/succeeded/cancelled/failed`。
- 控制操作在全局 dispatch 入口直接访问注册表，不等待账号会话锁或公开软件库长操作，因此可以在上传、下载或跨源搜索仍运行时轮询和请求取消。取消是协作式的；被取消的数据操作最终返回 `cancelled` 错误。
- 管理下载与公开软件库本地下载都使用真实字节进度，`library_download` 的 `kind` 复用 `download`；跨源搜索在每个源/页的有界工作点检查取消，`completedUnits/totalUnits` 表示已完成源数/总源数，`itemsFound` 表示当前结果数。
- 注册表最多保留 128 项。满额时只淘汰最早的终态项；`operation_forget` 也只允许清理 `succeeded/cancelled/failed` 终态，不能清理仍在 `running/cancelling` 的操作。

### 公开软件库响应边界

- `catalog_summary/page/browse/search/describe/resolve/download` 是 LanzouYOU 内置 LanzouMax 目录的正式高层入口。Rust 打包的 `s/h/c` 当前解析为 **597 个官方源 + 9 个合集，共 606 个顶层入口与 3370 个节点**；节点类型为 `remoteSource=597 / composite=9 / file=2730 / singleSoftware=34`，其中可搜索官方源 274 个。这些数字由 Rust 从打包资产计算，Flutter 不得写死。
- catalog 访问码只保存在 Rust 私有索引/操作目标中；`CatalogTarget` 刻意不实现 `Serialize` 或 `Debug`。Flutter 只传 `nodeId` 或无密码 `itemRef`，Dart 适配器还会拒绝响应中出现 `password/cookie/accessCode`等字段。
- `catalog_page` 默认批大小 100、最大 200，用与 revision/父节点/分类/查询绑定的 opaque cursor 分批返回；Flutter 使用惰性列表消费，不逐项 FFI、不解析 `s/h/c`。
- `library_probe/browse/search/collect/resolve/download/describe` 只处理公开分享协议，`library_fetch_asset` 只处理受信远程图标；八个公开操作都不能调用账号管理写接口，也不共享管理端 Cookie jar。
- 低层 `library_search.sources[]` 使用 `sourceId`、`title`、`shareUrl`、`password`，当前 Rust 有界上限为 4096 项；这是安全边界，**不是内置源总数**。正式全源界面必须调用 catalog 高层入口，由 Rust 展开 597 个官方源和合集；低层响应仍不得回显访问码或 Cookie。
- 当前 LanzouMax 目录解析策略已同步到 Rust：`library_probe` 始终分别用 Android/Desktop UA 探测，按可用项目数与耗时择优，之后的目录请求按规范源记忆优选 UA 并保留回退。minimal/classic/reflow/unknown 模板分别使用对应的首页/后续页间隔；`zt=4` 只对当前 UA 和页阶段动态退避，上限 8400 ms。源偏好缓存最多 512 项并确定性淘汰最旧项。
- LanzouMax 允许的旧域名写法只会在 production 输入阶段把分享路径规范到 `https://www.lanzouw.com`，不会放宽实际网络请求白名单。内部虚拟目录 fragment 会保留，普通 query/fragment 会丢弃；取消分享统一返回 `share_cancelled` 和安全文案。
- 普通软件源和分享/简介页面只允许 `lanzouw.com`、`lanzoui.com` 及其普通 ASCII 子域；拒绝 URL 凭据、尾点、IDN、明文 HTTP 和任何显式端口，页面重定向与 Ajax 端点逐跳保持该边界。最终下载直链另行要求 HTTPS 且无凭据、显式端口或 fragment；精确受信的蓝奏与 `dmpdmp.com` CDN 主机不依赖本机 DNS 公网分类，以兼容代理/TUN 的 `198.18.0.0/15` fake-IP。其他主机只执行一次 DNS 解析，所有结果均为公网地址后才把这些地址直接绑定到请求，不允许校验与连接之间再次解析；IP 字面量、IPv4/IPv6 私网/回环/链路本地/保留地址、映射或兼容地址以及 NAT64 内嵌私网地址均会拒绝。
- 仅 `library_resolve` 与内部复用相同解析链的 `library_download` 二次验证 bootstrap 可额外进入受信 `*.dmpdmp.com`：必须为 HTTPS、无 URL 凭据与显式端口，初始和后续路径都位于 `/file` 或 `/file/` 下；每一跳保持初始 origin，Ajax 端点还必须位于 `/file/**/ajax.php`。
- `library_download` 要求 `destinationDirectory` 是绝对目录路径；路径缺失时创建目录，已存在时必须确为目录。它只返回实际 `path`、安全 `fileName` 与 `bytesWritten`，不返回最终直链。传输先在目标目录创建隐藏且唯一的 `.part`，成功后以不覆盖语义原子发布；同名目标已存在、取消、失败或 15 秒读取空闲超时都会清理临时文件。访问码只作为当前请求输入，不进入响应、错误、下载历史或日志。
- `library_describe` 只读取文件分享页，HTTP 正文最多 2 MiB、简介最多 8192 字符；列表接口没有简介时由 Shell 在选中文件后懒加载。所有公开操作的远端错误都必须脱敏配置访问码。
- `library_fetch_asset` 只接受 `image.dmpdmp.com`，以及 `images.bakstotre.com/assets/images/type/` 路径的 HTTPS 图标地址；拒绝 URL 凭据、显式端口、HTTP、跨 origin 与私网地址，每一跳都重新校验。输入最多 1 MiB，只接受常见图片类型，解码后缩放到不超过 256×256 并重新编码，响应固定为严格 `{"mediaType":"image/png","bytesBase64":"..."}`。Flutter 只严格解码并渲染返回的 PNG bytes，不执行 `Image.network`。
- 直链兑换先等待 1900 ms；只有远端明确返回 pending 时才复用同一 endpoint、表单、referer 与 Cookie 会话，等待 250 ms 后再交换一次。终态的取消分享与访问码错误不会被重试覆盖，解析阶段、二次等待和网络正文读取都协作响应操作取消。
- 公开网络请求共享一个进程级长寿命 Tokio runtime，固定 2 个异步 worker，并把 DNS/reqwest 阻塞工作限制在最多 8 个 blocking worker；每个 transport 只保存 runtime handle。系统 DNS 一旦开始便无法强制 abort，但取消后调用会在约 25 ms 轮询边界返回，transport 析构不会等待仍在执行的 DNS；后台阻塞工作完成后由共享 runtime 正常回收，也不会阻止其他未饱和操作继续执行。
- 搜索 API 只作快速路径，即使 API 声称已返回完整总数，仍会以 BFS 递归补全可信目录树，并按结果 URL/虚拟目录键去重。同一源的 API 与目录阶段允许重叠，但只占一个活跃源逻辑名额；进程级固定 32 个 worker 是所有搜索共享的物理上限。慢源到达 `sourceSwitchDelayMs` 后轮转到队尾并立即用等待源补位，已完成和后续结果都保留；每个网络步骤有独立 12 秒硬上限，取消以最多约 20–25 ms 的调度/传输轮询粒度传播。源数量、查询长度、页数、逻辑并发量、目录数与结果数都有上限；不使用无限并发或无限翻页抓取。搜索 API 返回的绝对链接只接受现有精确受信 Lanzou 域族，广告域、伪装域、凭据、显式端口与非 ASCII 主机均丢弃。

### 离线重打包响应边界

- `library_repackage_android` 返回 `apkPath`、`sha256`、`certificateSha256`、`packageName`、`versionName`、`versionCode`，不返回私钥。
- `library_repackage_windows` 返回 `archivePath`、`sha256`、`exeName`。
- 两个操作都拒绝模板与输出同路径、危险 ZIP 条目、重复条目、超限归档、未知 recipe 字段和已存在的输出文件，并在写入后回读关键身份信息。
- Android 模板最低支持 API 24，输出使用 v2 签名；`.so` 存储项保持 16 KiB 对齐。Windows 输出只是便携 ZIP，不是在 Android 或 Windows 上重新编译源码。

## 4. 功能状态表

状态含义：

- **源码已接线，待最终门禁**：当前磁盘上的 Flutter/Rust 调用链存在，但本轮尚未完成全量测试、真实只读 smoke、双端构建、性能基线和 Final Audit；不得等同于交付完成。
- **已实现**：稳定的既有能力；本轮未改动部分仍只在其原证据边界内表述。
- **未完成**：只有目标、禁用行或局部基础，没有可用的端到端能力；不得宣称支持。
- **生产 FFI 登录冒烟**：当前构建的 Rust 动态库使用已授权账号完成登录、会话读取、根目录首屏列表和注销。
- **生产 FFI 管理冒烟**：只对本次创建的临时目录和文件执行写入、回读、回收站与清理闭环；不把用户既有条目作为测试对象。
- **生产只读实测**：使用已授权会话读取过真实 Woozooo 响应，但没有执行破坏性动作。
- **生产写入实测**：在用户明确授权范围内完成过写入并回读验证；不代表已经由当前客户端 UI 发起。
- **未生产实测**：只有源码、本地 fixture 或进程内 HTTP mock 证据。

| 能力 | 当前状态 | 证据与边界 |
|---|---|---|
| Flutter Windows + Android 共用 UI | 已实现 | Material 3、共享控制器和页面；平台壳只负责加载对应动态库 |
| Windows 简体中文字体渲染 | 已实现 | 保留 Segoe UI 主字体并显式设置有序中文/符号回退；Android 继续使用平台字体 |
| FFI envelope 与全部 `op` 解析 | 源码已接线，待最终门禁 | 当前 `Command` 为 45 个操作：25 个管理、7 个 catalog、8 个低层公开库、2 个离线重打包、3 个操作控制；最终通过数待质量门禁记录 |
| Cookie 安全恢复 | 已实现 | Flutter 使用 `flutter_secure_storage`；`session_info` 不返回 Cookie |
| 账号密码登录 | 已实现；生产 FFI 登录与管理冒烟通过 | 当前 Rust FFI 已完成 `login → session_info(authenticated) → 根目录首屏 list → logout`，并为后续管理闭环建立会话。认证管理页的 gzip 响应已有自动解压回归测试；SmartCaptcha/风控交互尚未接入，不能承诺所有账号与网络环境始终直登 |
| 目录/文件列表与分页 | 已实现；生产只读实测 | Woozooo 真实根目录清单计数与回读一致 |
| 新建、改名、移动、删除、分享、提取码 | 已实现；生产 FFI 管理冒烟通过 | 临时对象已覆盖新建目录、文件改名、文件移入/移出、目录移动、分享读取、提取码设置/清除和删除；提取码下载边界见下文 |
| 简介读取与写入 | 已实现；生产写入与 FFI 管理冒烟通过 | 已授权批量写入逐项回读成功；管理冒烟另以临时文件完成写入和回读，文档不保存私有条目 |
| 普通文件上传 | 已实现；生产 FFI 管理冒烟通过 | `html5up.php` 流程已用临时文件上传并回读；上传是非幂等动作，不自动并发重放；传输页显示当前字节/总字节并可请求取消 |
| 下载与直链解析 | 已实现；公开下载生产 FFI 管理冒烟通过 | 覆盖分享页、`ajaxm.php?file=...`、重定向、二次验证和 `acw_sc__v2`；传输页显示字节进度并可请求取消，取消或失败会清理 `.part`；带提取码的边缘 POST 当前返回 405，不能标记为端到端通过 |
| 任意扩展名兼容包 | 已实现，未生产实测 | 上传时追加可校验包尾，下载时原地还原；不是绕过账号容量限制 |
| 目录递归移动/复制 | 已实现；文件复制与目录移动生产 FFI 管理冒烟通过 | Woozooo 没有原子目录移动；目录递归复制仍以本地测试为主，多步模拟失败时可能产生部分结果 |
| 回收站读取、恢复、永久删除、清空 | 已实现；单项恢复与永久删除生产 FFI 管理冒烟通过 | 动态 `formhash` HTML 流程已实测；文件恢复到账号根目录，不自动回到删除前目录。`recycle_empty` 未用于生产冒烟，永久删除不可撤销 |
| 本地图标查找、提取与压缩 | 已实现，本地测试 | Flutter 可查找同 stem sidecar；Rust 可解码图片、提取 APK launcher，并在 Windows 使用 Win32 提取 EXE 图标；输出最大 144×144、严格小于 100,000 字节的 PNG |
| Woozooo 文件自定义图标绑定 | 已实现；协议生产写入与 FFI 管理冒烟通过 | Flutter `prepare_icon/set_icon`、Rust 四段协议和本地 HTTP mock 已接通；管理冒烟使用固定本地图标完成绑定并回读，另一次授权批量操作也完成逐项回读与像素验证 |
| 原生个人中心 | 源码已接线，聚焦测试通过 | Flutter 窄屏使用子页、宽屏使用主从布局，原生还原“我的权限、财务充值、文件升级、下载提现、提现记录、邀请注册、密码修改、手机号、注销账户”9 个入口；每项先展示应用内详情，需官方确认的操作才进入精确白名单页面 |
| VIP 识别与会员充值 | 源码已接线，聚焦测试通过 | Rust 仅根据个人页明确标签识别 `vip/free/unknown`，并解析等级和到期日；过期标签或已过期日期归为 `free`。Flutter 原生展示套餐选择、权益和风险提示，应用不读取或提交付款资料，最终购买仅在用户二次确认后打开 `profile/huiyuan` |
| 会员个性化 | 源码已接线，聚焦测试通过 | Flutter 原生列出免广告下载、上传时间显示、子文件夹、搜索、默认文件密码、头像、下载页模板、发布者昵称、日报、保存时间、直链域名 11 项；当前写端点未完成生产写入/回读验证，全部保持只读，不伪造开关成功 |
| Rust 内置 catalog 与真实公共列表 | 源码已接线，待最终门禁 | `assets/catalog/{s,h,c}` 与 Java canonical 资产字节和 SHA-256 一致；Rust 索引为 597 官方源、9 合集、2730 文件、34 单软件，共 3370 节点。`catalog_*` 承担分页、真实浏览、搜索、详情、解析和下载，访问码不出 Rust |
| LanzouYOU 公共软件库 UI | 源码已接线，待最终门禁 | 登录页有“免登录浏览软件库”入口；登录后一级“软件库”打开 `PublicLibraryPage`，而非生成器。页面使用惰性列表/分页、搜索取消、目录/单软件/详情状态；待 Android/Windows 可见验收 |
| 独立蓝奏设置 | 源码已接线，部分未完成 | 设置首页只有“蓝奏”入口，子页已展示真实 catalog 统计与账号内容；源管理、导入/导出、重测/重置和搜索/下载行为 actions 当前未接真实 capability，禁用行不算支持 |
| Flutter 可配置软件库壳 | 已实现（聚焦门禁有证据） | `project/LanzouLibraryShell` 共用 Material 3 UI、低层公开库 `op`、来源/分类 picker、双分享、来源回跳、下载筛选/真实动作、脱敏路径、持久历史与系统打开；config/search 上限可容纳 606 顶层入口，SafeArea/高缩放/reduced-motion 有聚焦证据 `verification/lanzou-shell-flutter-finalize-20260716`。它是生成产物的成品壳，不是 LanzouYOU 内置 3370 节点 catalog；跨层构建/真实源仍待父任务门禁 |
| LanzouYOU 生成软件库 | 源码存在，入口迁移未完成 | 生成器不再占用一级“软件库”导航；当前磁盘源码仍保留文件夹菜单预填入口，“设置 → 蓝奏 → 工具”的新项目生成入口尚未接线，不得宣称已迁移完成 |
| SourceRegistry/用户源持久化 | 未完成 | 尚无 Rust 事务 overlay、导入/导出/重测/重置闭环；现有设置行默认禁用 |
| 跨源搜索增量批次 | 未完成 | Rust 有有界并发搜索与操作进度，但当前 `catalog_search` 向 Flutter 返回单次最终结果，还没有首批/后续批次流式事件契约 |
| Range 断点续传与暂停/继续 | 未完成 | 当前公共下载是单任务 `.part` + 不覆盖原子发布，支持取消/重试；不是严格 Range/Content-Range 暂停恢复引擎 |
| 保存到优享 | 未完成 | 尚无多账号、按账号多选、逐项成功/失败和空间不足等真实错误闭环 |
| Android APK 离线重打包 | 已实现 | `library_repackage_android` 修改预构建模板并 v2 签名；最终 SDK 签名/对齐检查与实机结果以当前质量门禁为准 |
| Windows x64 ZIP 离线重打包 | 已实现 | `library_repackage_windows` 修改预构建便携模板；Android 版 LanzouYOU 也能生成该 ZIP，但不会在 Android 上编译 Windows 程序 |

### 自定义软件库 recipe v1

生成器和成品壳共用一份 canonical recipe：

| 区域 | 固定字段 |
|---|---|
| `identity` | `projectId`, `displayName`, `applicationId`, `versionName`, `versionCode`, `windowsExeName` |
| `branding` | `seedColor`, `officialUrl`, `publisher`, `logoAsset`, `themeMode` |
| `sources[]` | `sourceId`, `title`, `shareUrl`, `password`, `searchable`, `recommended` |
| `features` | `browse`, `search`, `download`, `showDescription` |

`schemaVersion` 当前只能为 `1`，`logoAsset` 固定为 `assets/runtime/logo.png`。需要区分两套目录：LanzouYOU 内置 catalog 直接打包 Rust `s/h/c`，能表达当前 597 官方源、9 合集和 3370 节点；自定义成品壳仍使用扁平 `sources[]` recipe。当前 Shell loader 已允许最多 4096 源，但 LanzouYOU builder 与 Rust repackage 校验仍是 1–512，存在跨层漂移；在三层统一且通过契约测试前，不得宣称生成器已完整承载 597 源。LanzouYOU 的脱敏工程副本不得包含 `password` 字段或非空的本地图标源路径；最终 APK/ZIP 为了访问受访问码保护的公开源会包含运行时访问码，因此使用者不应把访问码当作能在客户端中保密的凭据。

recipe 自身仍为 `schemaVersion: 1`；预构建模板集另由 `templates-manifest.json` 的 `schemaVersion: 2` 约束 generation `runId`、恰好 Android/Windows 两个目标、两个固定文件名及其字节数/SHA-256、core ABI 版本/两个固定导出符号和 recipe schema。LanzouYOU 会注入式读取 AssetBundle，先加载清单与两份模板并计算实际字节 SHA-256，整代全部通过后才返回任一模板；解析错误只显示固定安全文案，缓存也只保存完整验证的一代。

生成流程固定为：校验 recipe → 校验同一 schema 2 generation manifest 绑定的不可变预构建模板 → 生成独立临时作业 → 完成所有目标重打包 → 重算摘要并回读身份 → 一次批量提交 → 清理临时作业。维护者模板构建先在同一 staging generation 完成两份模板及 manifest 校验，再原子切换整代资源，失败则保留上一代；成功后仅删除 release 根层旧兼容入口，`generations/<runId>/` 不可变代保持不动。命令行最终用户多目标以单一目录原子发布；Flutter 双目标只保存一次完整 ZIP，内部恰含 APK、Windows ZIP 与去密 manifest。生成页的主动取消在当前目标完成后立即阻止后续目标与导出，保存窗口取消和主动取消统一显示“已取消”，任一目标失败或取消时外部零新增且临时作业清理。

## 5. 已实测 Woozooo 接口矩阵

写入和管理闭环结果来自 2026-07-14 的一次明确授权操作；个人中心只读页面证据来自 2026-07-15 的授权 GET 探针。这里只保留用途、结论和计数，不保留会话、签名、文件名、链接或 ID。

| 接口/任务 | 用途 | 实测结果 | 当前 core |
|---|---|---|---|
| `mlogin.php` | 账号登录 | 当前 Rust FFI 登录成功，后续会话、根目录列表和注销均成功 | `login` 已生产冒烟 |
| `mydisk.php` 文件页 | 初始化管理会话与读取目录上下文 | 会话页读取成功 | `login` / `restore_session` 会调用 |
| `mydisk.php?item=profile&action=mypower` | 个人权限、会员状态和账号入口 | 授权 GET 页面已确认入口与账号事实表面；未执行个人资料写入 | `account_capabilities` 结构化解析并脱敏返回 |
| `mydisk.php?item=profile&action=huiyuan` | 会员套餐与会员个性化 | 授权 GET 页面已确认套餐/续费/升级表面和 11 类个性化权益；没有已验证的客户端写入端点 | `account_capabilities` 只读解析；最终购买/设置仍由官方页面确认 |
| `doupload.php` `task=47` | 目录列表 | 目标目录唯一，无目录歧义 | `list` 第 1 页已实现 |
| `doupload.php` `task=5` | 文件分页 | 读取到 83 个文件，归一化名称无重名 | `list` 已实现 |
| `doupload.php` `task=12` | 文件信息与简介回读 | 69 项简介逐项一致；标记计数与列表一致 | `share_info` 内部已使用 |
| `doupload.php` `task=11` | 写入文件简介 | 69/69 成功，失败 0 | `set_description` 已实现 |
| `doupload.php` `task=46` | 文件改名 | 临时文件改名与回读成功；Woozooo 保留原扩展名，因此请求只发送目标 stem | `rename` 已按文件/目录分支处理，并有回归测试 |
| `doupload.php` `task=41` | 获取图标绑定状态并建立短期关联上下文 | 83 项授权与最终回读成功 | `set_icon` 已实现 |
| 签名 `imgup.woozooo.com` OSS multipart | 上传图标对象 | 83/83 成功 | `set_icon` 已实现，并精确限制 HTTPS host |
| `doupload.php` `task=38`, `type=2` | 把 OSS 图标关联到文件 | 83/83 成功 | `set_icon` 已实现；结果不明确时不盲目重放 |
| `task=41` 后置回读与图片下载 | 验证最终图标 | `is_ico=1` 共 83 项；逐项图片像素验证失败 0 | core 会校验后置状态和可信回读 host；像素下载比对属于授权探针证据，尚未进入客户端 |

没有列入本表的接口不得仅凭源码存在就标记为“生产实测”。上表的批量计数来自独立授权操作；下面的管理闭环来自当前 Rust FFI，并且只使用临时对象。

### 当前 Rust FFI 管理闭环

当前构建的动态库已经完成以下真实顺序并回读通过：

1. 登录、新建临时目录、上传临时文件。
2. 设置简介、设置与清除提取码、使用固定本地图标设置文件图标、读取分享信息。
3. 在无提取码状态解析并下载公开文件，核对下载结果。
4. 文件改名、移入子目录、移回、复制；单项移入回收站后恢复，再次移入并永久删除；移动临时目录。
5. 精确清理本次创建的临时文件和目录，并回读确认没有残留；测试没有调用全局清空回收站。

已确认的协议边界：

- Woozooo `task=46` 会保留文件原扩展名。core 对文件改名会把调用方提供的完整目标名转换成 stem 再发送，避免生成重复扩展名；目录改名仍发送完整名称。
- 回收站文件恢复到账号根目录，而不是删除前所在目录。需要恢复到业务目录的流程必须在恢复后显式移动并回读验证。
- 提取码设置、状态回读与清除已分别通过；无提取码的公开下载也已通过。当前带提取码分享页的边缘下载 POST 返回 HTTP 405，这是上游边缘接口限制，因此不能把两项独立成功合并宣称为“带提取码下载端到端通过”。

## 6. 真实自定义图标协议

真实文件图标不是把 PNG 当普通网盘文件上传。已验证的顺序固定为：

1. 校验目标是文件，并验证输入是可解码的 PNG/JPG/GIF/BMP；原图可直接绑定，但字节数必须**严格小于 100,000 字节**。需要提取、缩放、改格式或压缩时先用 `prepare_icon` 生成 PNG；等于边界也不能上传。
2. 在同一账号的串行会话中调用 `doupload.php task=41`，取得本次绑定的短期上下文，并只在内存 Cookie jar 中更新它。
3. 在该上下文中读取短期 OSS 表单；只接受 HTTPS、443 端口、无 URL 凭据且 host 精确为 `imgup.woozooo.com` 的地址，然后执行 multipart 上传。
4. OSS 成功后，调用 `doupload.php task=38` 且 `type=2` 完成文件关联。
5. 再调用 `task=41` 回读，要求状态已绑定且图标 URL 为 HTTPS、443 端口、无 URL 凭据、host 精确为 `image.dmpdmp.com`。授权批量验证还会下载图片做解码/像素比对；当前客户端 core 尚未执行像素比对，因此不能把一次 `set_icon` 成功等同于逐像素审计通过。

安全与一致性要求：

- `task=41 → OSS → task=38 → task=41` 必须按文件串行执行，并使用同一个可更新 Cookie jar；每次响应的 `Set-Cookie` 要原子合并，不能让并发任务用旧 Cookie 覆盖新 Cookie。
- 上传与回读只使用上述两个精确 host allowlist，不接受 `*.woozooo.com`、任意 CDN、明文 HTTP、非标准端口或跨 host 重定向。
- OSS 表单、对象键、策略和签名只保存在内存中，用后即弃；不得写日志、manifest、崩溃报告或测试快照。
- OSS 失败时不得调用 `task=38`；关联结果不明确时先回读 `task=41`，不要盲目重放写入。
- 批量任务应支持暂停、失败计数和逐项回读，不应为追求速度并发刷新同一账号会话。

### 自动图标可选流程

当前 Flutter 上传对话框已经提供可关闭的“自动获取并设置文件图标”选项：

1. 优先查找同 stem 或 `<stem>_icon` 的 PNG、JPG、JPEG、GIF、BMP sidecar；没有 sidecar 时把原文件交给 Rust。
2. Rust 可直接解码上述图片、从 APK 中选择可解码的高密度 launcher PNG/WebP，或在 Windows 使用 Win32 提取 EXE 图标；Android 不提供 EXE 图标提取，其他文件没有可提取图标时返回安全警告。
3. Rust 生成最大 144×144 的方形 PNG，并再次拒绝大于或等于 100,000 字节的输出。
4. 原文件上传成功后，优先使用上传响应中的文件 ID；缺少 ID 时只接受当前目录中唯一匹配项，歧义会中止绑定。
5. 调用 `set_icon` 完成本节协议。图标准备或绑定失败不会上传第二个图标文件，也不会把原文件上传误报为失败。

离线批量准备工具位于 `project/LanzouYOU/tool/prepare_local_icon_batch.py`。它使用 UTF-8-sig 读取、NFKC/trim/casefold 归一化、哈希文件名、zip-slip 防护和确定性压缩；安全 manifest 只包含计数、哈希和歧义数量，不包含私有条目。

## 7. 安全、限流与失败语义

- **凭据**：账号和密码只用于一次登录调用，不写配置、文档或日志。
- **会话**：Flutter 只把 Cookie 写入系统安全存储；Rust 只保存在内存中。注销、过期或恢复失败时清除两端状态。
- **个人中心与付款**：Flutter 只接受 `https://pc.woozooo.com/mydisk.php` 下精确的 `item/action` 允许列表，拒绝同域错误路径、额外参数、fragment、端口和 URL 凭据。会员套餐在原生界面选择，但应用不接收、读取或提交付款资料；所有最终付款仍由用户二次确认后在官方页面完成。
- **个性化写入**：未经过生产写入和回读验证的会员个性化项一律只读。页面出现控件或文案不能作为可写证据，不显示虚假开关或成功提示。
- **日志**：不记录完整请求/响应正文、Cookie、分享直链、OSS 字段或用户文件元数据。
- **TLS**：Rust 使用 rustls 并保持证书校验，不提供跳过 TLS 校验的兼容开关。
- **请求重试**：幂等 GET/下载最多 3 次并有限退避；普通 POST、普通上传、OSS 上传和图标关联遇到网络中断、5xx 或服务繁忙时不自动重放，而是返回“结果不明确”。`acw_sc__v2` 挑战可在受限次数内刷新后重试。
- **并发**：账号管理数据操作由全局会话锁串行，传输控制器也顺序排队；公开软件库搜索使用独立会话、活跃源调度和进程级 32-worker 执行器。三个操作控制绕过账号会话与公开软件库长锁，保证运行中可轮询和请求取消。若以后引入账号数据操作并发，图标绑定和 Cookie 更新仍必须按账号串行。
- **下载**：使用临时 `.part` 文件，成功后改名；失败时清理临时文件，不覆盖已存在目标。
- **目录模拟操作**：递归移动/复制不是服务端事务。开始前确认目标，失败后必须重新列目录并给出部分完成结果。
- **回收站**：永久删除和清空必须二次确认；测试不得使用生产数据。
- **公共解析隔离**：公开软件库 `op` 不得读取管理会话；访问码只作为请求输入，响应、远端错误和日志不得回显，非空访问码的远端错误固定为安全文案。普通源仅允许 `lanzouw.com`、`lanzoui.com` 及其普通 ASCII 子域，并拒绝显式端口、尾点与 IDN；仅 resolve 二次验证 bootstrap 可受限进入同一 HTTPS `*.dmpdmp.com` origin 的 `/file` 范围，每个重定向与 Ajax 路径都重新校验。精确受信的蓝奏/CDN 下载主机允许代理 fake-IP，本地或保留 IP 字面量以及非受信主机的非公网 DNS 结果仍拒绝。
- **模板归档**：重打包必须限制归档、条目、展开总量和运行时配置大小，拒绝 ZIP slip、重复路径、Windows 设备名、模板/输出同路径和既有输出覆盖；schema 2 模板 manifest 必须绑定同一 generation、目标、摘要、core ABI 和 recipe schema，多目标只允许整套原子发布。
- **Android 签名**：私钥只保存到调用方指定的本机应用支持目录，响应仅返回证书 SHA-256。签名身份丢失后不能用新签名覆盖升级相同应用标识的旧安装。
- **Windows 信誉**：生成器修改 PE 图标和版本资源但不提供商业代码签名；便携 EXE 可能触发 SmartScreen 或杀毒软件信誉检查，不能把“成功重打包”等同于“已获得系统信誉”。

Woozooo 管理接口是未公开 Web 协议，随时可能改变。解析器应保持 fixture 测试、明确错误码和可回退的功能开关，不能把“页面字段存在”当作长期稳定保证。

## 8. 构建与验证入口

在仓库根目录使用 PowerShell 7：

```powershell
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action Analyze
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action Test
pwsh -NoProfile -File .\command\Invoke-FlutterClient.ps1 -Action BuildAllDebug
```

可选动作：

- `PubGet`
- `BuildAndroidDebug` / `BuildAndroidRelease`
- `BuildWindowsDebug` / `BuildWindowsRelease`
- `InstallAndroidDebug` / `LaunchAndroidDebug` / `BuildInstallAndroidDebug`
- `RunWindowsDebug` / `BuildRunWindowsDebug`

`command/flutter-client-*.cmd` 提供常用动作的双击入口；项目特定名称 `Invoke-LanzouYOU.ps1` 只转发参数到统一脚本，不维护第二套构建逻辑。

### 软件库模板与最终用户生成

维护者需要更新随 LanzouYOU 分发的壳模板时使用：

```powershell
pwsh -NoProfile -File .\command\Build-LanzouLibraryTemplates.ps1
```

这是**维护期源码构建入口**：它会调用 Flutter/Cargo 构建 LanzouLibraryShell 的 Android APK 与 Windows x64 便携模板，在同一 staging generation 生成并校验 `schemaVersion: 2` manifest 后才原子切换 `project/LanzouYOU/assets/templates/` 整代资源；任一目标失败都保留上一代。release 证据只保存在 `release/LanzouLibraryShell_templates/release/generations/<runId>/`，成功发布后移除 release 根层三个旧兼容文件而不改动历史 generation。模板构建完成后，最终用户生成不再需要这些工具链。

一级“软件库”导航已专用于真实公共 catalog，不再是生成器。生成器是辅助工具，目标入口是“设置 → 蓝奏 → 工具”；当前源码仍保留文件夹菜单的“生成软件库”预填入口，新设置工具入口尚未接线。在 Android 或 Windows 上均可选择 Android APK、Windows x64 ZIP 或两者；Android 生成 Windows ZIP 只是修改预构建 Windows 模板，并不在 Android 上编译 Windows。

Windows 上也可以把已有 recipe 交给脚本：

```powershell
pwsh -NoProfile -File .\command\Build-CustomLanzouLibrary.ps1 -RecipePath .\recipe.json
```

`Build-CustomLanzouLibrary.ps1` 是**最终用户本地重打包入口**：只读取本地 recipe、schema 2 manifest 约束的内置模板和固定预构建 Rust core，不联网下载，不调用 Flutter、Gradle 或 Cargo，不触发远程构建。它先在 staging 中完成全部目标生成、摘要复核与身份回读，再以单一目录原子发布；其 `-DryRun` 只做配置、模板和输出计划检查，不创建产物。

模板存在只证明资源已准备，不等于重打包产物可安装。完成发布前仍须分别验证 Android APK 的包名/名称/版本、16 KiB 对齐、v2 签名与实机启动，以及 Windows ZIP 的运行时配置、EXE 名称/资源和解压启动。`Verify-LanzouLibraryGeneratedArtifacts.ps1` 只有在全部校验和所选启动冒烟通过后，才以 UTF-8 JSON 原子写入输出目录的 `verification-result.json`；每次开始验证先移除同目录旧结果，因此启动失败不会留下可误认的新旧 `pass` 证据。

### LanzouMax 显式发布与远端字节回读

本机 CurrentUser 受保护发布凭据已初始化时，APK、版本号、图标和凭据仍由固定位置读取，但必须显式选择动作：

```powershell
pwsh -NoProfile -File .\command\Publish-LanzouMax.ps1 -DryRun
pwsh -NoProfile -File .\command\Publish-LanzouMax.ps1 -Publish
pwsh -NoProfile -File .\command\Publish-LanzouMax.ps1 -VerifyReadback
```

发布器的固定契约如下：

- APK 固定读取工作区相对路径 `release/lanzou-native-java_android/local/LanzouMax.apk`；图标固定读取应用资源 `project/lanzou-native-java/app/src/main/res/mipmap-nodpi/app_icon.jpg`，不写死工作区绝对路径。
- 使用本机 Android SDK 的 `aapt2` 自动读取 APK `versionName`，最终云端名称固定为 `LanzouMax<versionName>.apk`。
- 固定图标已经是 235×235、7,920 字节的合规 JPEG，发布器把原文件直接交给 `set_icon`；不会从 APK 提取图标，不调用 `prepare_icon`，也不生成 PNG 或再次压缩。
- 两个目标目录都先上传唯一暂存项、写入固定简介 `官网链接:https://lanzoumax.nkbr.cc/`、设置图标并回读，再进入替换阶段。
- LanzouMax 归档目标只把与本地 `versionName` 相同的旧 APK 删除到回收站并替换，其他历史版本保留；软件合集目标会替换所有完整匹配当前产品命名规则的旧项。
- 任一目录失败时清理本次暂存项并回滚两边：旧文件从回收站恢复到账号根目录后，再移回各自原目标目录，并按 ID 与名称回读；恢复、移动或验证任一步失败都会报告 `rollback=incomplete`。
- `-VerifyReadback` 在两个固定目标中唯一定位本版本最终文件，下载到 D/H 盘受控临时目录，逐个复核字节数和 SHA-256 与本地 APK 完全一致，随后清理临时文件；输出只包含目标数、通过数和 SHA-256。

未显式提供 `-DryRun`、`-Publish` 或 `-VerifyReadback` 时脚本会拒绝执行；`-?` 只显示帮助。测试数量和正式证据以当前 Verification 日志为准。

产物归档到：

- Android：`release/LanzouYOU_Android/<debug|release>/`
- Windows：`release/LanzouYOU_Windows/<debug|release>/`

Rust core 单独验证：

```powershell
Set-Location .\project\LanzouYOU\native\lanzouyou_core
cargo fmt --all --check
cargo check --all-targets
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

当前 Shell finalize 的聚焦 Flutter 验证证据位于 `verification/lanzou-shell-flutter-finalize-20260716`。LanzouYOU 全量 Flutter、Rust core、Android/Windows 构建、真实公共列表/单软件 smoke、性能基线与 Final Audit 仍由父任务门禁记录；未实际完成前不在本文预写通过数。

## 9. OpenList 参考边界

协议实现固定参考 OpenList commit [`eb48671202247406a451187a8c62fae943acfc3b`](https://github.com/OpenListTeam/OpenList/tree/eb48671202247406a451187a8c62fae943acfc3b/drivers/lanzou)，避免随上游滚动变化造成不可复现结果。

- OpenList 使用 AGPL-3.0；它是协议行为参考，不是可以无条件复制进闭源客户端的代码素材。
- LanzouYOU Rust core 是独立实现，当前不包含 OpenList 源文件。
- 若未来复制、修改、链接或分发 OpenList 派生代码，必须先完成许可证评估、保留版权与许可证通知，并履行适用的 AGPL 源码提供义务。
- “根据网络行为重新实现”不等于自动免除所有法律义务；正式分发前仍应做许可证与服务条款审查。

OpenList 的实现存在与当前 Woozooo 页面不一致的旧登录字段，因此固定 commit 只用于可追溯参考，不能替代对当前页面和真实响应的验证。
