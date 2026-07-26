# LanzouYOU Rust Core

`lanzouyou_core` 是 LanzouYOU 的同步 Rust 网络与文件核心，产出 `cdylib` 和 `rlib`。Flutter 必须在 Dart isolate 中调用，避免同步上传、下载阻塞 UI isolate。

## C ABI

仅导出两个符号：

```c
char *lanzouyou_dispatch(const char *request_json);
void lanzouyou_free(char *response_json);
```

调用方必须用 `lanzouyou_free` 释放响应。所有响应固定为：

```json
{"ok":true,"data":{},"error":null}
```

或：

```json
{"ok":false,"data":null,"error":{"code":"...","message":"...","retriable":false}}
```

## Dispatch schema

### 账号管理（22 个）

- `login {account,password}`
- `restore_session {cookie}` / `logout {}` / `session_info {}`
- `list {folderId,page?,pageSize?}` / `move_targets {}`
- `mkdir {parentId,name,description}`
- `rename {id,isFolder,name}` / `move {id,isFolder,targetId}` / `delete {id,isFolder}`
- `share_info {id,isFolder}` / `set_password {id,isFolder,password}` / `set_description {id,isFolder,description}`
- `upload {folderId,path,compatWrap?,kind?,operationId?}`，`kind` 仅为 `auto|file`
- `prepare_icon {sourcePath,outputPath?}` / `set_icon {fileId,path}`
- `download {id,name?,destination,operationId?}`
- `copy {id,isFolder,name,targetId,tempDir}`
- `recycle_list {}` / `recycle_restore {id,isFolder}` / `recycle_purge {id,isFolder}` / `recycle_empty {}`

以上为 22 个账号管理 `op`，与 Dart `RustCloudService` 和 `docs/lanzouyou-api.md` 的契约表一一对应。

### 公开软件库（8 个）

- `library_probe {source}` / `library_browse {sourceId,shareUrl,password,page?,refresh?}`
- `library_search {query,sources,options?,operationId?}` / `library_collect {items,sources}`
- `library_resolve {sourceId,shareUrl,password}` / `library_download {sourceId,shareUrl,password?,destinationDirectory,operationId?}`
- `library_describe {sourceId,shareUrl,password}`
- `library_fetch_asset {url}`

### 离线重打包（2 个）

- `library_repackage_android {templatePath,outputPath,runtimeConfig,iconPath?,signingIdentityPath}`
- `library_repackage_windows {templatePath,outputPath,runtimeConfig,iconPath?}`

### 操作控制（3 个）

- `operation_status {operationId}`
- `operation_cancel {operationId}`
- `operation_forget {operationId}`

四类合计 **35 个 `op`：22 个账号管理、8 个公开软件库、2 个离线模板重打包、3 个操作控制**。

`upload`、`download`、`library_download` 与 `library_search` 只有在调用方传入 `operationId` 时才注册为可控操作。标识必须是 1–64 位 ASCII 字母、数字、点、下划线或连字符；注册表最多保留 128 项，满额时只淘汰最早的终态项。`operation_status/cancel/forget` 绕过账号会话与公开软件库长锁，因此运行中的上传、下载和搜索可以被轮询或请求取消；`operation_forget` 只清理已经 `succeeded/cancelled/failed` 的终态项。固定状态字段为 `operationId`、`kind`、`state`、`completedUnits`、`totalUnits`、`bytesTransferred`、`totalBytes`、`itemsFound`：上传/下载报告字节进度，跨源搜索按源/页协作检查取消并报告已完成源数与结果数。

生产管理与上传端点固定为 `https://pc.woozooo.com` 和 `https://up.woozooo.com`。实现包含 gzip 响应自动解压、请求超时、幂等 GET 的有限重试、非幂等结果不明确保护、`acw_sc__v2`、cookie 过期映射、列表分页、递归目录移动/复制、回收站操作，以及任意扩展名的兼容包尾上传/下载还原。

Woozooo 的文件改名 `task=46` 会保留原扩展名；`rename` 的文件分支会从调用方给出的完整目标名中取 stem 再发送，目录分支仍发送完整名称。回收站文件恢复后位于账号根目录，不保证回到删除前目录；上层需要恢复到指定目录时必须再调用 `move` 并回读确认。

`prepare_icon` 支持直接图片、APK launcher，以及 Windows 上的 Win32 EXE 图标提取，输出最大 144×144、严格小于 100,000 字节的 PNG；Android 不提取 EXE。`set_icon` 在同一串行会话中执行 `task 41 → 短期 OSS → task 38(type=2) → task 41`，响应只返回 `fileId`。OSS 只允许 HTTPS `imgup.woozooo.com`，回读只允许 HTTPS `image.dmpdmp.com`；不接受 host 通配、URL 凭据、非标准端口或跨 host 重定向。短期表单与对象键不写入响应、日志或磁盘。

公开软件库使用与管理端 Cookie 隔离的会话。production 输入会先把 LanzouMax 兼容的旧域名写法的分享路径规范到 `https://www.lanzouw.com`，但实际普通分享页网络请求仍只允许 `lanzouw.com`、`lanzoui.com` 及其普通 ASCII 子域，并拒绝 URL 凭据、尾点、IDN 与任何显式端口；二次验证仅能进入同一受信 `*.dmpdmp.com` origin 的 HTTPS `/file` 范围，重定向和 Ajax 路径逐跳复核。目录探测始终比较 Android/Desktop UA 并记忆优选，按当前 HTML 模板分离首页/后续页节流，`zt=4` 退避上限 8400 ms；直链兑换首次等待 1900 ms，只有远端明确仍为 pending 时才在同一 endpoint/form/referer/Cookie 会话中等待 250 ms 后再交换一次。搜索把同一源的 API 快路与 BFS 目录补全并行调度，以活跃源而不是阶段数计算逻辑并发；进程级固定 32 个 worker 承担物理网络工作，慢源到达 `sourceSwitchDelayMs` 后轮转到队尾并立即补位，结果不会丢弃。每个网络步骤有 12 秒硬上限，解析、搜索、退避和下载都协作响应操作取消。请求和源偏好缓存均以 512 源为上限。公开网络请求共享进程级长寿命 Tokio runtime，其中异步 worker 固定为 2、包括 DNS 在内的 blocking worker 上限为 8；已由操作取消而分离的 OS 阻塞工作不会在 `LibraryTransport` 析构时反向卡住调用线程，释放后仍可安全复用运行时。非受信直链只解析一次 DNS，要求所有地址均为公网，并把已验证地址直接绑定到实际请求，避免校验后再次解析；IPv4、IPv6、映射/兼容地址与 NAT64 内嵌私网均会阻断。`library_fetch_asset` 只允许 `image.dmpdmp.com`，以及 `images.bakstotre.com/assets/images/type/` 路径；每一跳保持 HTTPS 同源并阻断私网地址，输入最多 1 MiB，解码后缩放到不超过 256×256，固定返回 `{"mediaType":"image/png","bytesBase64":"..."}`。

`library_download` 复用同一真实解析会话，并逐跳验证直链后把响应流写入 `destinationDirectory` 内的唯一隐藏 `.part`。下载不设全局总时长上限，持续分段传输的大文件不会因总耗时被中断；单次网络读取的空闲上限为 15 秒，停滞后会有界返回，并在该边界检查取消请求。文件名由远端标题净化并拦截路径穿越、控制字符及 Windows 设备名；成功以平台 no-clobber 原子发布，已有同名文件固定返回 `already_exists`，取消或失败会清理临时文件。若底层文件系统不支持任何安全原子发布方式，则返回 `atomic_publish_unsupported`，不会退回可覆盖目标的普通重命名。成功数据只包含 `path`、`fileName`、`bytesWritten`，不会返回直链或访问码。

两个重打包 `op` 只修改单份预构建模板，不调用 Flutter、Gradle 或 Cargo。外层模板集由 `templates-manifest.json` 的 `schemaVersion: 2` 同时绑定 generation `runId`、目标集合、文件大小/SHA-256、core ABI 版本/导出符号与 recipe schema；维护者构建和最终用户多目标生成均先完成整套 staging 与回读验证，再原子发布，失败时不留下半套新产物。

核心不记录账号、密码、cookie 或响应正文。`login` / `restore_session` 的 `data.cookie` 仅用于交给 Flutter 安全存储；`session_info` 不返回 cookie。

## 实现依据

- OpenList `drivers/lanzou` 固定版本 `eb48671202247406a451187a8c62fae943acfc3b`：登录、`doupload.php` 任务、分页、上传和分享直链流程。
- LanZouCloud-API 固定版本 `3bb917f6baf873d83b1e8e6fb2df74c60c4d8cb3`：目录递归移动、回收站表单、格式限制和兼容上传行为。

OpenList 使用 AGPL-3.0；本 crate 只把固定 commit 作为可追溯的协议行为参考，是独立 Rust 实现且不包含上述项目源码。若未来复制、修改、链接或分发 OpenList 派生代码，必须先评估并履行适用的 AGPL 义务。自动化测试只连接进程内本地 HTTP mock。

## 验证

```powershell
cargo fmt --all --check
cargo check --all-targets
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

当前 `cargo test --all-targets --all-features` 结果为 **185 项单元测试与 6 项 dispatch contract 测试全部通过**，其中包含 gzip 认证页面、文件改名只发送 stem、上传/下载字节进度与取消、下载停滞有界返回和长时分段传输、直链 pending 同会话二次交换、DNS 地址绑定与 IPv4/IPv6 特殊地址、已启动阻塞解析工作期间的有界取消/transport 析构/后续操作隔离、双 UA 探测、模板节流、动态退避、取消分享、全局搜索 worker 上限、API/目录重叠、慢源轮转与快速取消、控制操作并发旁路、公开下载重定向、二次验证逐跳约束、安全图标转码和 Android/Windows 离线重打包等回归。自动化测试和本地 TCP HTTP mock 本身不进行真实登录，也不会调用破坏性网络接口。

2026-07-14 的独立授权生产冒烟使用当前 Rust FFI 完成了登录、authenticated 会话读取、根目录首屏列表和注销；管理冒烟只使用本次创建的临时对象，完成新建目录、上传、简介、提取码设置与清除、固定图标绑定、分享读取、公开下载、改名、文件移动与复制、回收站恢复与永久删除、目录移动和精确清理。测试没有调用全局清空回收站。

提取码管理和无提取码公开下载已经分别验证；当前带提取码分享页的边缘下载 POST 返回 HTTP 405，属于上游接口限制，尚不能标记为带提取码下载端到端通过。SmartCaptcha/风控也可能随账号和网络环境变化，单次成功不能替代后续兼容维护。更多证据边界见 [`docs/lanzouyou-api.md`](../../../../docs/lanzouyou-api.md)。

## LanzouMax 发布器调用边界

工作区 `command/Publish-LanzouMax.ps1` 固定读取 APK 与应用资源 JPEG，但要求显式选择 `-DryRun`、`-Publish` 或 `-VerifyReadback`。脚本通过 APK `versionName` 自动生成 `LanzouMax<versionName>.apk`；发布路径把合规 `app_icon.jpg` 原样传给 `set_icon`，回读路径则只在两个固定目录下载唯一最终文件并复核大小和 SHA-256。

发布器对两个目标目录执行暂存、简介、图标和回读后再替换。归档目录只回收同版本旧项并保留其他历史，软件合集目录回收全部完整名称匹配项。失败回滚使用 `recycle_restore` 后调用 `move` 返回原目标目录；远端字节回读使用 core `download` 写入 D/H 盘受控临时目录，失败闭合并清理。测试数量以当前 Verification 日志为准。
