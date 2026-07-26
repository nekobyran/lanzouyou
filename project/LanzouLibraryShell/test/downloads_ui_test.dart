import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/controllers/library_controller.dart';
import 'package:lanzou_library_shell/models/download_history.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/pages/downloads/downloads_page.dart';
import 'package:lanzou_library_shell/pages/library/library_page.dart';
import 'package:lanzou_library_shell/repositories/download_history_repository.dart';
import 'package:lanzou_library_shell/services/download_coordinator.dart';
import 'package:lanzou_library_shell/services/download_file_opener.dart';
import 'package:lanzou_library_shell/services/download_storage_paths.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/link_opener.dart';
import 'package:lanzou_library_shell/shared/app_theme.dart';

void main() {
  test('retry does not enqueue a second task for the same item', () async {
    final entry = _history(
      id: 'duplicate',
      name: '重复软件',
      status: DownloadHistoryStatus.failed,
      errorCode: 'network',
    );
    final downloads = ControlledDownloadCoordinator()
      ..seed(
        history: [entry],
        active: const [
          DownloadSnapshot(
            operationId: 'active-duplicate',
            historyId: 'active-duplicate',
            itemStableKey: 'main|duplicate',
            fileName: 'duplicate.apk',
            state: DownloadActivityState.queued,
            bytesTransferred: 0,
            totalBytes: 0,
          ),
        ],
      );
    final controller = LibraryController(
      config: _config(download: true),
      core: _FakeLibraryCore(),
      downloads: downloads,
    );
    addTearDown(controller.dispose);

    await controller.retryDownload(entry);

    expect(downloads.retried, isEmpty);
    expect(controller.downloadActionError, '此项目已在下载队列中');
  });

  test('unknown source IDs fail closed without starting a download', () async {
    final downloads = ControlledDownloadCoordinator();
    final controller = LibraryController(
      config: _config(download: true),
      core: _FakeLibraryCore(),
      downloads: downloads,
    );
    addTearDown(controller.dispose);

    await controller.downloadItem(
      const LibraryItem(
        sourceId: 'unknown',
        title: '未知来源软件',
        url: 'https://www.lanzouw.com/iunknown',
        shareUrl: 'https://www.lanzouw.com/iunknown',
        isFolder: false,
      ),
    );

    expect(downloads.downloadRequests, isEmpty);
    expect(controller.detailError, '文件来源不可用，无法下载');
  });

  test(
    'retry reports an actionable error when its source was removed',
    () async {
      final entry = _history(
        id: 'removed-source',
        name: '已移除来源软件',
        status: DownloadHistoryStatus.failed,
        sourceId: 'removed',
        errorCode: 'network',
      );
      final downloads = ControlledDownloadCoordinator()
        ..seed(history: [entry], active: const []);
      final controller = LibraryController(
        config: _config(download: true),
        core: _FakeLibraryCore(),
        downloads: downloads,
      );
      addTearDown(controller.dispose);

      await controller.retryDownload(entry);

      expect(downloads.retried, isEmpty);
      expect(controller.downloadActionError, '原软件源已移除，无法重新下载');
    },
  );

  test(
    'dispose awaits download shutdown before closing the core once',
    () async {
      final downloads = GatedDownloadCoordinator()
        ..seed(
          history: [
            _history(
              id: 'shutdown',
              name: '关闭中的任务',
              status: DownloadHistoryStatus.downloading,
            ),
          ],
          active: const [
            DownloadSnapshot(
              operationId: 'shutdown',
              historyId: 'shutdown',
              itemStableKey: 'main|shutdown',
              fileName: 'shutdown.apk',
              state: DownloadActivityState.downloading,
              bytesTransferred: 1,
              totalBytes: 2,
            ),
          ],
        );
      final core = _LifecycleLibraryCore();
      final controller = LibraryController(
        config: _config(download: true),
        core: core,
        downloads: downloads,
      );

      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(downloads.shutdownCalls, 1);
      expect(core.closeCalls, 0);

      downloads.releaseShutdown();
      await core.closed.future.timeout(const Duration(seconds: 1));
      expect(core.closeCalls, 1);

      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(downloads.shutdownCalls, 1);
      expect(core.closeCalls, 1);
    },
  );

  testWidgets(
    'download capability adds adaptive destinations, real path and working back',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final downloads = ControlledDownloadCoordinator();
      final config = _config(download: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
          home: LibraryPage(
            config: config,
            core: _FakeLibraryCore(),
            linkOpener: _NoopLinkOpener(),
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final compactNavigation = tester.widget<NavigationBar>(
        find.byKey(const Key('compact-navigation-bar')),
      );
      expect(compactNavigation.destinations, hasLength(3));
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('downloads-page')), findsOneWidget);
      expect(find.text(r'~\Downloads'), findsOneWidget);
      expect(find.text(downloads.saveDirectory), findsNothing);
      expect(find.byType(Card), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('compact-home-scroll')), findsOneWidget);

      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('compact-home-scroll')), findsOneWidget);

      tester.view.physicalSize = const Size(1000, 800);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsNothing);
      expect(
        find.byKey(const Key('wide-download-destination')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('wide-download-destination')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('downloads-page')), findsOneWidget);
      expect(find.text('下载历史'), findsOneWidget);
    },
  );

  testWidgets('detail action uses real download states and never opens a URL', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final downloads = ControlledDownloadCoordinator();
    final config = _config(download: true);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
        home: LibraryPage(
          config: config,
          core: _FakeLibraryCore(),
          linkOpener: _NoopLinkOpener(),
          downloads: downloads,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试安装包'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '下载'), findsOneWidget);
    expect(find.text('解析并打开'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '下载'));
    await tester.pump();
    expect(downloads.downloadRequests, ['测试安装包']);
    expect(find.text('正在解析下载地址'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '取消下载'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '下载状态' &&
            widget.properties.value == '正在解析下载地址' &&
            widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );

    downloads.updateProgress(bytesTransferred: 2048, totalBytes: 4096);
    await tester.pump();
    expect(find.text('已下载 2.0 KB / 4.0 KB · 50%'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '下载状态' &&
            widget.properties.value == '已下载 2.0 KB / 4.0 KB · 50%' &&
            widget.properties.liveRegion == false,
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, '取消下载'));
    await tester.pump();
    expect(find.text('下载已取消'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新下载'), findsOneWidget);
  });

  testWidgets('history is a searchable divided list with real actions', (
    tester,
  ) async {
    final downloads = ControlledDownloadCoordinator()
      ..seed(
        history: [
          _history(
            id: 'completed',
            name: '完成软件',
            status: DownloadHistoryStatus.succeeded,
            bytes: 8192,
            filePath: r'C:\Users\tester\Downloads\completed.apk',
          ),
          _history(
            id: 'interrupted',
            name: '中断软件',
            status: DownloadHistoryStatus.failed,
            bytes: 2048,
            errorCode: 'interrupted',
            errorMessage: '上次下载未完成，可以重试',
          ),
        ],
        active: [
          const DownloadSnapshot(
            operationId: 'active',
            historyId: 'active',
            itemStableKey: 'main|active',
            fileName: 'active.apk',
            state: DownloadActivityState.downloading,
            bytesTransferred: 1024,
            totalBytes: 4096,
          ),
        ],
      );
    downloads.addHistory(
      _history(
        id: 'active',
        name: '正在下载软件',
        status: DownloadHistoryStatus.downloading,
        bytes: 1024,
      ),
    );
    final config = _config(download: true);
    final controller = LibraryController(
      config: config,
      core: _FakeLibraryCore(),
      downloads: downloads,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
        home: Scaffold(
          body: DownloadsPage(
            controller: controller,
            searchFocusNode: FocusNode(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Card), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.text('正在下载软件'), findsOneWidget);
    expect(find.text('完成软件'), findsOneWidget);
    expect(find.text('中断软件'), findsOneWidget);
    expect(find.text(r'~\Downloads'), findsOneWidget);
    expect(find.text(downloads.saveDirectory), findsNothing);
    final localTimestamp = DateTime.utc(2026, 7, 14, 1).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    expect(
      find.textContaining(
        '${localTimestamp.year}-${two(localTimestamp.month)}-'
        '${two(localTimestamp.day)} ${two(localTimestamp.hour)}:'
        '${two(localTimestamp.minute)}',
      ),
      findsWidgets,
    );

    await tester.enterText(
      find.byKey(const Key('download-history-search')),
      '完成',
    );
    await tester.pump();
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('完成软件'), findsOneWidget);
    expect(find.text('中断软件'), findsNothing);
    await tester.tap(find.byTooltip('打开文件'));
    await tester.pump();
    expect(downloads.opened, ['completed']);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    await tester.tap(find.byTooltip('重新下载'));
    await tester.pump();
    expect(downloads.retried, ['interrupted']);
  });

  testWidgets(
    'byte polling rebuilds only its row and respects reduced motion',
    (tester) async {
      final downloads = ControlledDownloadCoordinator();
      downloads.seed(
        history: [
          _history(
            id: 'first',
            name: '第一项',
            status: DownloadHistoryStatus.downloading,
          ),
          _history(
            id: 'second',
            name: '第二项',
            status: DownloadHistoryStatus.queued,
          ),
        ],
        active: const [
          DownloadSnapshot(
            operationId: 'first',
            historyId: 'first',
            itemStableKey: 'main|first',
            fileName: 'first.apk',
            state: DownloadActivityState.downloading,
            bytesTransferred: 0,
            totalBytes: 0,
          ),
          DownloadSnapshot(
            operationId: 'second',
            historyId: 'second',
            itemStableKey: 'main|second',
            fileName: 'second.apk',
            state: DownloadActivityState.queued,
            bytesTransferred: 0,
            totalBytes: 0,
          ),
        ],
      );
      final config = _config(download: true);
      final controller = LibraryController(
        config: config,
        core: _FakeLibraryCore(),
        downloads: downloads,
      );
      addTearDown(controller.dispose);
      var structureBuilds = 0;
      final rowBuilds = <String, int>{};
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: buildLibraryTheme(
              config.branding.seedColor,
              Brightness.light,
            ),
            home: Scaffold(
              body: DownloadsPage(
                controller: controller,
                searchFocusNode: focusNode,
                debugOnStructureBuild: () => structureBuilds++,
                debugOnRowBuild: (key) {
                  rowBuilds[key] = (rowBuilds[key] ?? 0) + 1;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final stableStructureBuilds = structureBuilds;
      final firstBuilds = rowBuilds['active:first']!;
      final secondBuilds = rowBuilds['active:second']!;
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.byType(LinearProgressIndicator), findsNothing);

      downloads.updateProgress(
        operationId: 'first',
        bytesTransferred: 1024,
        totalBytes: 4096,
      );
      await tester.pump();

      expect(structureBuilds, stableStructureBuilds);
      expect(rowBuilds['active:first'], firstBuilds + 1);
      expect(rowBuilds['active:second'], secondBuilds);
      expect(find.textContaining('已下载 1.0 KB / 4.0 KB · 25%'), findsOneWidget);
    },
  );

  testWidgets(
    'only causal row and state changes animate while byte ticks stay still',
    (tester) async {
      final downloads = ControlledDownloadCoordinator()
        ..seed(
          history: [
            _history(
              id: 'first',
              name: '第一项',
              status: DownloadHistoryStatus.downloading,
              bytes: 1024,
            ),
          ],
          active: const [
            DownloadSnapshot(
              operationId: 'first',
              historyId: 'first',
              itemStableKey: 'main|first',
              fileName: 'first.apk',
              state: DownloadActivityState.downloading,
              bytesTransferred: 1024,
              totalBytes: 4096,
            ),
          ],
        );
      final config = _config(download: true);
      final controller = LibraryController(
        config: config,
        core: _FakeLibraryCore(),
        downloads: downloads,
      );
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
          home: Scaffold(
            body: DownloadsPage(
              controller: controller,
              searchFocusNode: focusNode,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final baselineEntrances = find
          .byType(TweenAnimationBuilder<double>)
          .evaluate()
          .length;
      expect(tester.hasRunningAnimations, isFalse);

      downloads.updateProgress(
        operationId: 'first',
        bytesTransferred: 2048,
        totalBytes: 4096,
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);

      downloads.addActiveTask(id: 'new', name: '新任务');
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      expect(
        find.byType(TweenAnimationBuilder<double>).evaluate().length,
        baselineEntrances + 1,
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('download-history-search')),
        '第一项',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expect(
        find.byType(TweenAnimationBuilder<double>).evaluate().length,
        baselineEntrances,
      );

      downloads.updateState('first', DownloadActivityState.cancelling);
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);
      expect(find.byTooltip('正在取消下载'), findsOneWidget);
    },
  );

  testWidgets('history filters real states and semantic file suffixes', (
    tester,
  ) async {
    final downloads = ControlledDownloadCoordinator()
      ..seed(
        history: [
          _history(
            id: 'resolving',
            name: '解析任务',
            status: DownloadHistoryStatus.resolving,
            fileName: 'resolver.apk',
          ),
          _history(
            id: 'running',
            name: '视频任务',
            status: DownloadHistoryStatus.downloading,
            fileName: 'movie.mp4',
          ),
          _history(
            id: 'failed',
            name: '压缩包失败',
            status: DownloadHistoryStatus.failed,
            fileName: 'archive.zip',
            errorCode: 'network',
          ),
          _history(
            id: 'cancelled',
            name: '文档已取消',
            status: DownloadHistoryStatus.cancelled,
            fileName: 'manual.pdf',
          ),
          _history(
            id: 'completed',
            name: '安装包完成',
            status: DownloadHistoryStatus.succeeded,
            fileName: 'release.apk',
            bytes: 4096,
            filePath: r'C:\Users\tester\Downloads\release.apk',
          ),
        ],
        active: const [
          DownloadSnapshot(
            operationId: 'resolving',
            historyId: 'resolving',
            itemStableKey: 'main|resolving',
            fileName: 'resolver.apk',
            state: DownloadActivityState.resolving,
            bytesTransferred: 0,
            totalBytes: 0,
          ),
          DownloadSnapshot(
            operationId: 'running',
            historyId: 'running',
            itemStableKey: 'main|running',
            fileName: 'movie.mp4',
            state: DownloadActivityState.downloading,
            bytesTransferred: 1024,
            totalBytes: 4096,
          ),
        ],
      );
    final config = _config(download: true);
    final controller = LibraryController(
      config: config,
      core: _FakeLibraryCore(),
      downloads: downloads,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
        home: Scaffold(
          body: DownloadsPage(
            controller: controller,
            searchFocusNode: FocusNode(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.widgetWithText(FilterChip, '解析中'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '安装包'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, '解析中'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('解析任务'), findsOneWidget);
    expect(find.text('视频任务'), findsNothing);
    expect(find.text('安装包完成'), findsNothing);

    downloads.updateState('resolving', DownloadActivityState.downloading);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('解析任务'), findsNothing, reason: '真实任务状态跨过筛选边界时必须立即移出列表');

    await tester.tap(find.widgetWithText(FilterChip, '下载失败'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('压缩包失败'), findsOneWidget);
    expect(find.text('文档已取消'), findsOneWidget);
    expect(find.text('解析任务'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, '全部').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilterChip, '安装包'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('解析任务'), findsOneWidget);
    expect(find.text('安装包完成'), findsOneWidget);
    expect(find.text('视频任务'), findsNothing);
    expect(find.text('压缩包失败'), findsNothing);
  });

  testWidgets(
    'selection exposes only real batch controls and uses a custom confirm dialog',
    (tester) async {
      final downloads = ControlledDownloadCoordinator()
        ..seed(
          history: [
            _history(
              id: 'active',
              name: '正在下载软件',
              status: DownloadHistoryStatus.downloading,
            ),
          ],
          active: const [
            DownloadSnapshot(
              operationId: 'active',
              historyId: 'active',
              itemStableKey: 'main|active',
              fileName: 'active.apk',
              state: DownloadActivityState.downloading,
              bytesTransferred: 1024,
              totalBytes: 4096,
              bytesPerSecond: 1024,
            ),
          ],
        );
      final config = _config(download: true);
      final controller = LibraryController(
        config: config,
        core: _FakeLibraryCore(),
        downloads: downloads,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
          home: Scaffold(
            body: DownloadsPage(
              controller: controller,
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1.0 KB/s · 剩余约 3 秒'), findsOneWidget);

      await tester.longPress(find.text('正在下载软件'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);
      await tester.tap(find.byTooltip('所选下载操作'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('暂停/继续'), findsOneWidget);
      expect(find.textContaining('当前下载核心不支持断点续传'), findsOneWidget);
      await tester.tap(find.text('取消所选下载'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('取消 1 个下载？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '取消下载'));
      await tester.pumpAndSettle();

      expect(downloads.cancelled, ['active']);
      expect(find.textContaining('下载已取消'), findsOneWidget);
    },
  );

  testWidgets('narrow high-scale filters remain scrollable without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final downloads = ControlledDownloadCoordinator()
      ..seed(
        history: [
          _history(
            id: 'narrow',
            name: '窄屏安装包',
            status: DownloadHistoryStatus.failed,
          ),
        ],
        active: const [],
      );
    final config = _config(download: true);
    final controller = LibraryController(
      config: config,
      core: _FakeLibraryCore(),
      downloads: downloads,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
          home: Scaffold(
            body: DownloadsPage(
              controller: controller,
              searchFocusNode: FocusNode(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('download-state-filters')), findsOneWidget);
    expect(find.byKey(const Key('download-extension-filters')), findsOneWidget);
  });
}

class ControlledDownloadCoordinator extends DownloadCoordinator {
  factory ControlledDownloadCoordinator() {
    final runtime = _NoopDownloadRuntime();
    return ControlledDownloadCoordinator._(runtime);
  }

  ControlledDownloadCoordinator._(_NoopDownloadRuntime runtime)
    : super(
        downloadCore: runtime,
        operationCore: runtime,
        repository: _NoopHistoryRepository(),
        paths: const FixedDownloadStoragePaths(
          downloadsPath: r'C:\Users\tester\Downloads',
          applicationSupportPath: r'C:\Users\tester\AppData\Local\shell',
        ),
        fileOpener: _NoopDownloadFileOpener(),
      );

  List<DownloadHistoryEntry> _controlledHistory = const [];
  List<DownloadSnapshot> _controlledActive = const [];
  int _sequence = 0;

  final List<String> downloadRequests = [];
  final List<String> opened = [];
  final List<String> retried = [];
  final List<String> cancelled = [];
  final List<String> deletedFiles = [];

  @override
  List<DownloadHistoryEntry> get history =>
      List.unmodifiable(_controlledHistory);

  @override
  List<DownloadSnapshot> get active => List.unmodifiable(_controlledActive);

  @override
  bool get isLoading => false;

  @override
  String get loadError => '';

  @override
  String get persistenceWarning => '';

  @override
  String get saveDirectory => r'C:\Users\tester\Downloads';

  @override
  Future<void> initialize() async {}

  void seed({
    required List<DownloadHistoryEntry> history,
    required List<DownloadSnapshot> active,
  }) {
    _controlledHistory = List.of(history);
    _controlledActive = List.of(active);
  }

  void addHistory(DownloadHistoryEntry entry) {
    _controlledHistory = [entry, ..._controlledHistory];
  }

  void addActiveTask({required String id, required String name}) {
    final entry = _history(
      id: id,
      name: name,
      status: DownloadHistoryStatus.queued,
    );
    _controlledHistory = [entry, ..._controlledHistory];
    _controlledActive = [
      DownloadSnapshot(
        operationId: id,
        historyId: id,
        itemStableKey: 'main|$id',
        fileName: '$id.apk',
        state: DownloadActivityState.queued,
        bytesTransferred: 0,
        totalBytes: 4096,
      ),
      ..._controlledActive,
    ];
    notifyListeners();
  }

  void updateState(String operationId, DownloadActivityState state) {
    _controlledActive = [
      for (final task in _controlledActive)
        if (task.operationId == operationId)
          task.copyWith(state: state)
        else
          task,
    ];
    _controlledHistory = [
      for (final entry in _controlledHistory)
        if (entry.operationId == operationId)
          entry.copyWith(
            status: _historyStatusFor(state),
            updatedAt: entry.updatedAt.add(const Duration(seconds: 1)),
          )
        else
          entry,
    ];
    notifyListeners();
  }

  @override
  Future<String> download({
    required String sourceId,
    required String shareUrl,
    required String password,
    required String itemStableKey,
    required String displayName,
    String suggestedFileName = '',
  }) async {
    final id = 'ui-download-${++_sequence}';
    downloadRequests.add(displayName);
    final now = DateTime.utc(2026, 7, 14, 2, _sequence);
    final entry = DownloadHistoryEntry(
      id: id,
      operationId: id,
      sourceId: sourceId,
      shareUrl: shareUrl,
      itemStableKey: itemStableKey,
      displayName: displayName,
      suggestedFileName: suggestedFileName,
      filePath: '',
      status: DownloadHistoryStatus.resolving,
      bytesTransferred: 0,
      totalBytes: 0,
      createdAt: now,
      updatedAt: now,
    );
    _controlledHistory = [entry, ..._controlledHistory];
    _controlledActive = [
      DownloadSnapshot(
        operationId: id,
        historyId: id,
        itemStableKey: itemStableKey,
        fileName: suggestedFileName,
        state: DownloadActivityState.resolving,
        bytesTransferred: 0,
        totalBytes: 0,
      ),
      ..._controlledActive,
    ];
    notifyListeners();
    return id;
  }

  void updateProgress({
    String? operationId,
    required int bytesTransferred,
    required int totalBytes,
  }) {
    final id = operationId ?? _controlledActive.first.operationId;
    _controlledActive = [
      for (final task in _controlledActive)
        if (task.operationId == id)
          task.copyWith(
            state: DownloadActivityState.downloading,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
          )
        else
          task,
    ];
    _controlledHistory = [
      for (final entry in _controlledHistory)
        if (entry.operationId == id)
          entry.copyWith(
            status: DownloadHistoryStatus.downloading,
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            updatedAt: entry.updatedAt.add(const Duration(seconds: 1)),
          )
        else
          entry,
    ];
    notifyListeners();
  }

  @override
  Future<void> cancel(String operationId) async {
    cancelled.add(operationId);
    final now = DateTime.utc(2026, 7, 14, 3);
    _controlledActive = _controlledActive
        .where((task) => task.operationId != operationId)
        .toList();
    _controlledHistory = [
      for (final entry in _controlledHistory)
        if (entry.operationId == operationId)
          entry.copyWith(
            status: DownloadHistoryStatus.cancelled,
            updatedAt: now,
            completedAt: now,
            errorCode: 'cancelled',
            errorMessage: '已取消下载',
          )
        else
          entry,
    ];
    notifyListeners();
  }

  @override
  Future<String> retry(
    DownloadHistoryEntry entry, {
    required String password,
  }) async {
    retried.add(entry.id);
    return 'retried-${entry.id}';
  }

  @override
  Future<void> open(DownloadHistoryEntry entry) async {
    opened.add(entry.id);
  }

  @override
  Future<void> deleteHistory(String id) async {
    _controlledHistory = _controlledHistory
        .where((entry) => entry.id != id)
        .toList();
    notifyListeners();
  }

  @override
  Future<void> deleteFileAndHistory(DownloadHistoryEntry entry) async {
    deletedFiles.add(entry.id);
    await deleteHistory(entry.id);
  }

  @override
  Future<void> clearHistory() async {
    _controlledHistory = const [];
    notifyListeners();
  }

  @override
  Future<void> shutdown() async {}
}

class GatedDownloadCoordinator extends ControlledDownloadCoordinator {
  GatedDownloadCoordinator() : super._(_NoopDownloadRuntime());

  final Completer<void> _shutdownGate = Completer<void>();
  Future<void>? _shutdown;
  int shutdownCalls = 0;

  @override
  Future<void> shutdown() => _shutdown ??= _waitForShutdown();

  Future<void> _waitForShutdown() async {
    shutdownCalls++;
    await _shutdownGate.future;
  }

  void releaseShutdown() {
    if (!_shutdownGate.isCompleted) _shutdownGate.complete();
  }
}

DownloadHistoryStatus _historyStatusFor(DownloadActivityState state) =>
    switch (state) {
      DownloadActivityState.queued => DownloadHistoryStatus.queued,
      DownloadActivityState.resolving => DownloadHistoryStatus.resolving,
      DownloadActivityState.downloading => DownloadHistoryStatus.downloading,
      DownloadActivityState.cancelling => DownloadHistoryStatus.cancelling,
      DownloadActivityState.succeeded => DownloadHistoryStatus.succeeded,
      DownloadActivityState.cancelled => DownloadHistoryStatus.cancelled,
      DownloadActivityState.failed => DownloadHistoryStatus.failed,
    };

DownloadHistoryEntry _history({
  required String id,
  required String name,
  required DownloadHistoryStatus status,
  int bytes = 0,
  String filePath = '',
  String errorCode = '',
  String errorMessage = '',
  String sourceId = 'main',
  String? fileName,
}) {
  final terminal = status.isTerminal;
  final timestamp = DateTime.utc(2026, 7, 14, 1);
  return DownloadHistoryEntry(
    id: id,
    operationId: id,
    sourceId: sourceId,
    shareUrl: 'https://www.lanzouw.com/i$id',
    itemStableKey: 'main|$id',
    displayName: name,
    suggestedFileName: fileName ?? '$id.apk',
    filePath: filePath,
    status: status,
    bytesTransferred: bytes,
    totalBytes: status == DownloadHistoryStatus.succeeded ? bytes : 4096,
    createdAt: timestamp,
    updatedAt: timestamp,
    completedAt: terminal ? timestamp : null,
    errorCode: errorCode,
    errorMessage: errorMessage,
  );
}

class _FakeLibraryCore implements LibraryCore {
  @override
  Future<LibraryProbeResult> probe(LibrarySource source) async =>
      LibraryProbeResult(
        source: LibraryProbeSource(
          sourceId: source.sourceId,
          title: source.title,
          shareUrl: source.shareUrl,
          searchable: source.searchable,
        ),
        folder: await browse(
          sourceId: source.sourceId,
          shareUrl: source.shareUrl,
        ),
      );

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async => LibraryFolder(
    sourceId: sourceId,
    title: '主源',
    url: shareUrl,
    items: const [
      LibraryItem(
        sourceId: 'main',
        title: '测试安装包',
        url: 'https://www.lanzouw.com/itest',
        shareUrl: 'https://www.lanzouw.com/itest',
        isFolder: false,
      ),
    ],
  );

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async => const LibrarySearchResult();

  @override
  Future<LibraryCollectResult> collect({
    required List<LibraryItem> items,
    required List<LibrarySource> sources,
  }) async => LibraryCollectResult(files: items, foldersScanned: 0);

  @override
  Future<LibraryResolveResult> resolve({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryResolveResult(url: '', fileName: '');

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async => const LibraryDescribeResult(description: '测试简介');
}

class _LifecycleLibraryCore extends _FakeLibraryCore
    implements LibraryCoreLifecycle {
  final Completer<void> closed = Completer<void>();
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
    if (!closed.isCompleted) closed.complete();
  }
}

class _NoopDownloadRuntime
    implements LibraryDownloadCore, LibraryOperationCore {
  @override
  Future<LibraryDownloadResult> download({
    required String sourceId,
    required String shareUrl,
    String password = '',
    required String destinationDirectory,
    String? operationId,
  }) => throw UnimplementedError();

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) =>
      throw UnimplementedError();

  @override
  Future<void> cancelOperation(String operationId) async {}

  @override
  Future<void> forgetOperation(String operationId) async {}
}

class _NoopHistoryRepository implements DownloadHistoryRepository {
  @override
  Future<List<DownloadHistoryEntry>> load() async => const [];

  @override
  Future<void> replaceAll(List<DownloadHistoryEntry> entries) async {}

  @override
  Future<void> upsert(DownloadHistoryEntry entry) async {}

  @override
  Future<void> remove(String id) async {}

  @override
  Future<void> clear() async {}
}

class _NoopDownloadFileOpener implements DownloadFileOpener {
  @override
  Future<void> open(String filePath) async {}
}

class _NoopLinkOpener implements LinkOpener {
  @override
  Future<void> open(String url) async {}
}

LibraryConfig _config({required bool download}) => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'download_ui',
    'displayName': '下载测试库',
    'applicationId': 'cc.example.downloadui',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'download_ui',
  },
  'branding': {
    'seedColor': '#6750A4',
    'themeMode': 'light',
    'officialUrl': '',
    'publisher': '',
    'logoAsset': 'assets/runtime/logo.png',
  },
  'sources': [
    {
      'sourceId': 'main',
      'title': '主源',
      'shareUrl': 'https://www.lanzouw.com/broot',
      'password': '',
      'searchable': true,
      'recommended': true,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': download,
    'showDescription': true,
  },
});
