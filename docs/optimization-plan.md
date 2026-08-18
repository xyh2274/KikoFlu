# KikoFlu 下载缓存优化整合方案

> 基于本地下载缓存优化资源（参照 `d:\MyBlog\kikoeru\README.md` 及 `kikoeru-optimized-source.zip`）梳理。
> 本方案为 Flutter/Riverpod 技术栈下的**优化点移植**，本地原生 Java（`com.zinhao.kikoeru`）源码仅作逻辑蓝本，不直接搬用。

## 1. 背景与目标

本地有一份针对**原生 Android Kikoeru（Java）**的下载缓存优化实现，覆盖 19 项优化点。而 fork 仓库 `xyh2274/KikoFlu` 是 **Flutter/Dart** 跨平台客户端，技术栈不同，优化代码无法直接移植。本方案的目标是：**逐项核验这些优化点在 KikoFlu 中的现状，对缺失或偏弱的项按 Flutter 方式重新落地**，提升本地下载与缓存管理能力。

## 2. 现状核实结论

| 本地优化项 | KikoFlu 对应实现（文件） | 状态 |
|---|---|---|
| #1 自动清理 | `lib/src/services/cache_service.dart` `checkAndCleanCache`（5min 间隔 + 过期清理 + 超上限按修改时间清理） | ✅ 已具备 |
| #2 下载前空间检查 | 无 | ❌ 缺失 |
| #3 缓存/下载隔离 | `kikoeru_cache`/`kikoeru_audio_cache`（私有目录）与外部下载目录分离 | ✅ 已具备 |
| #4 workJson 字段 | 属服务端元数据结构，客户端无意义 | ➖ 跳过 |
| #5 全局存储预算 | `cacheSizeLimitKey` 默认 1GB 可配置 | ⚠️ 仅缓存，不含下载 |
| #6 文件完整性校验 | 无（下载完成仅 rename，未校验大小/hash） | ❌ 缺失 |
| #7 DB-磁盘一致性 | `lib/src/services/download_service.dart` `reloadMetadataFromDisk` | ✅ 已具备 |
| #8 下载状态 / 中断粒度 | `DownloadStatus` 5 态；`.downloading` 临时文件，resume 为整文件重下 | ✅ / ⚠️ 可补 Range 续传 |
| #9 并发下载 | `_maxConcurrentDownloads=20` + `_processQueue` 队列 | ✅ 已具备 |
| #10 重试策略 | 失败置 `failed`，需手动 resume，无自动重试 | ❌ 缺失 |
| #11 队列优先级 | pending FIFO，无优先级 | ❌ 缺失 |
| #12 状态字段 | 同 #8 | ✅ 已具备 |
| #13 历史冗余 | 属服务端/原版范畴 | ➖ 跳过 |
| #14 批量操作 | `lib/src/screens/downloads_screen.dart` 多选/全选 | ✅ 已具备 |
| #15 搜索历史上限 | `search_history_provider.dart` `_maxHistoryItems=20` | ✅ 已具备 |
| #16 下载进度可视化 | `DownloadTask.progress` + 进度条/速度 | ✅ 已具备 |
| #17 存储空间可视化 | 设置页仅一个缓存大小数字 | ⚠️ 较弱 |
| #18 一键清理缓存 | `settings_screen.dart` `clearAllCache` + 上限设置 | ✅ 已具备 |
| #19 下载完成智能提醒 | 无通知 | ❌ 缺失 |

## 3. 优化项详述

### P0 · 缺失项（优先实现）

#### O1 下载前剩余空间检查
- **现状/问题**：`addTask`/`_startDownload` 入队前不检查设备可用空间。
- **涉及文件**：`lib/src/services/download_service.dart`、`lib/src/services/download_path_service.dart`。
- **方案**：发起下载前用磁盘 API 获取目标下载目录可用空间，比对任务预估 `totalBytes`；不足时在 UI 拦截并提示"空间不足（需 X，可用 Y）"，可选预留阈值。
- **风险**：低；需注意多任务排队时累计占用估算。

#### O2 下载文件完整性校验
- **现状/问题**：下载完成仅 `tempFile.rename(filePath)`，未校验实际大小/摘要。
- **涉及文件**：`download_service.dart`。
- **方案**：rename 前校验实际字节数 ≥ 预期 `totalBytes`；对支持摘要的场景校验 hash。校验通过才置 `completed`，否则置 `failed` 并清理损坏临时文件。
- **风险**：低；用于音频的 `cache_service.finalizeAudioCacheFile` 已有 `expectedSize` 下限逻辑可复用思路。

#### O3 失败自动重试策略
- **现状/问题**：`DioException` 等错误直接置 `failed`，无自动重试。
- **涉及文件**：`download_service.dart`。
- **方案**：为 `failed` 任务加入指数退避重试（限次、可配置）；按错误类型分流（网络类重试，文件系统/4xx 不重试），避免对致命错误无限重试。
- **风险**：中；需避免与失败统计、重复保存交互。

#### O4 下载队列优先级
- **现状/问题**：`_processQueue` 按 pending 的 FIFO 顺序调度，无优先级。
- **涉及文件**：`models/download_task.dart`、`download_service.dart`、`downloads_screen.dart`。
- **方案**：`DownloadTask` 增加 `priority` 字段；`_processQueue` 按优先级排序取任务；UI 支持置顶/调整顺序。
- **风险**：中；需兼容 `SharedPreferences` 序列化（`toJson`/`fromJson`）。

#### O5 下载完成智能提醒
- **现状/问题**：批量下载完成无系统通知。
- **涉及文件**：`download_service.dart`、新增通知辅助（Android 需权限 + channel）。
- **方案**：一批任务全部完成时发系统通知；可选"完成后继续预约下一任务"。桌面端同步前台提示。
- **风险**：中；涉及平台渠道配置与权限。

### P1 · 已有但偏弱（可补强）

#### O6 全局存储预算扩展
- **现状/问题**：缓存上限只算缓存目录，未含下载目录占用。
- **方案**：`checkAndCleanCache` 统计时计入下载目录占用，形成全局预算（对齐本地 #5）。
- **风险**：中；下载文件为"用户资产"，清理策略需区分（缓存可自动删，下载默认不自动删，仅纳入统计）。

#### O7 存储空间可视化补强
- **现状/问题**：`settings_screen.dart` 只显示一个缓存大小数字和上限。
- **方案**：扩展为分项展示（缓存 / 音频缓存 / 图片 / 下载占用）+ 占用占比，可选环形图组件。
- **风险**：低。

#### O8 断点续传
- **现状/问题**：`resumeTask` 是将任务重置为 pending 后**整文件重下**。
- **方案**：基于 HTTP `Range` 从既有 `.downloading` 临时文件偏移续传（需服务器支持 `Accept-Ranges`）。
- **风险**：中+；受服务器与网络层限制，需先探测支持度并降级为整文件重下。

### P2 · 可选项

- O9 临时文件清扫：独立定时任务清理孤立 `.downloading`/`.part`（现仅在读缓存时顺带处理）。
- O10 一键清理分流：清理对话框增加"是否包含下载文件"选项。

## 4. 实施计划

| 阶段 | 内容 | 依赖 |
|---|---|---|
| 1 | O1 空间检查 + O2 完整性校验（改动独立、风险最低） | 无 |
| 2 | O3 自动重试 + O4 队列优先级 | 依赖阶段 1 的状态机 |
| 3 | O5 完成通知 | 平台配置 |
| 4 | O6/O7/O8 补强项 | 视进度与需求决定 |

## 5. 参考实现蓝本（本地原生版）

以下本地源码（`kikoeru-optimized-source.zip` / 优化文档）可作为逻辑参考：
- 空间检查：`cache/StorageChecker.java`（原工程）
- 自动清理：`cache/DownloadCleaner.java`（KikoFlu 已内建等价 `CacheService`，无需移植）
- 完整性校验：`cache/FileIntegrityVerifier.java`
- 一致性检查：`cache/DownloadConsistencyChecker.java`（KikoFlu 已内建 `reloadMetadataFromDisk`）

> 提示：迁移映射见上方第 2 节；KikoFlu 缓存能力本身已完善，本地 Java 的清理/一致性实现**不作为移植目标**，仅作思路参考。