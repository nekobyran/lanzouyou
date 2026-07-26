import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/app/library_shell_app.dart';
import 'package:lanzou_library_shell/config/library_config.dart';
import 'package:lanzou_library_shell/controllers/library_controller.dart';
import 'package:lanzou_library_shell/models/library_item.dart';
import 'package:lanzou_library_shell/pages/library/library_content.dart';
import 'package:lanzou_library_shell/pages/library/library_list.dart';
import 'package:lanzou_library_shell/pages/library/library_page.dart';
import 'package:lanzou_library_shell/pages/library/library_states.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/link_opener.dart';
import 'package:lanzou_library_shell/shared/app_motion.dart';
import 'package:lanzou_library_shell/shared/app_theme.dart';

void main() {
  testWidgets('uses one adaptive Material 3 tree at 390, 768 and 1440', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: FakeLibraryCore(),
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('compact-navigation-bar')), findsOneWidget);
    expect(find.byKey(const Key('compact-home-search')), findsOneWidget);
    expect(find.byKey(const Key('compact-home-source-grid')), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const Key('master-detail-layout')), findsNothing);
    final compactNavigation = tester.widget<NavigationBar>(
      find.byKey(const Key('compact-navigation-bar')),
    );
    expect(compactNavigation.destinations, hasLength(3));
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('个人'), findsOneWidget);
    expect(find.text('下载'), findsNothing);
    expect(find.textContaining('保存路径'), findsNothing);

    tester.view.physicalSize = const Size(768, 900);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const Key('wide-source-pane')), findsOneWidget);
    expect(find.byKey(const Key('wide-source-list')), findsOneWidget);
    expect(find.byKey(const Key('wide-source-main')), findsOneWidget);
    expect(find.byKey(const Key('master-detail-layout')), findsNothing);

    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const Key('wide-source-pane')), findsOneWidget);
    expect(find.byKey(const Key('wide-source-main')), findsOneWidget);
    expect(find.byKey(const Key('master-detail-layout')), findsOneWidget);
    expect(find.byKey(const Key('persistent-detail-pane')), findsOneWidget);
    expect(find.byType(SearchBar), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact home opens a real source and directory overview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..folderPublisher = '真实发布者'
      ..folderDescription = '这是由目录接口返回的真实来源简介。';

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试软件库'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('compact-home-source-grid')),
        matching: find.text('主源'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('compact-source-directory')), findsOneWidget);
    expect(find.byKey(const Key('compact-directory-grid')), findsOneWidget);
    expect(find.text('由 真实发布者 发布'), findsOneWidget);
    expect(find.text('这是由目录接口返回的真实来源简介。'), findsOneWidget);
    expect(find.byKey(const Key('breadcrumb-list')), findsOneWidget);
    expect(find.byTooltip('刷新当前目录'), findsOneWidget);
    expect(find.byType(LibraryCompactGridTile), findsNWidgets(2));

    await tester.tap(find.text('首页'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('compact-home-scroll')), findsOneWidget);

    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('compact-source-overview')), findsOneWidget);
    expect(
      find.byKey(const Key('compact-source-overview-grid')),
      findsOneWidget,
    );
    expect(find.text('全部来源 · 1'), findsOneWidget);
  });

  testWidgets('compact home search uses the real global search operation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore();

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('compact-home-search')), '编辑器');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(core.searchQueries, ['编辑器']);
    expect(find.byKey(const Key('compact-source-directory')), findsOneWidget);
    expect(find.text('没有匹配结果'), findsOneWidget);
    expect(find.text('下载'), findsNothing);
  });

  testWidgets(
    'animates real loading into content with semantic Material rows',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeLibraryCore()
        ..browseCompleter = Completer<LibraryFolder>();

      await tester.pumpWidget(
        LibraryShellApp.testHarness(
          config: testConfig(),
          core: core,
          linkOpener: FakeLinkOpener(),
        ),
      );
      await tester.pump();
      expect(find.text('正在加载软件目录'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == '正在加载软件目录' &&
              widget.properties.liveRegion == true,
        ),
        findsOneWidget,
      );

      core.browseCompleter!.complete(
        const LibraryFolder(
          sourceId: 'main',
          title: '主源',
          url: 'https://www.lanzouw.com/broot',
          items: [
            LibraryItem(
              sourceId: 'main',
              title: '真实文件',
              url: 'https://www.lanzouw.com/ireal',
              shareUrl: 'https://www.lanzouw.com/ireal',
              isFolder: false,
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(AppMotionEntrance), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.text('真实文件'), findsOneWidget);
      expect(find.text('正在加载软件目录'), findsNothing);
      final row = find.byType(LibraryDirectoryRow);
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(64));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.button == true &&
              widget.properties.label == '真实文件' &&
              widget.properties.selected == false,
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('builds a 1000 item directory lazily without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..rootItems = List<LibraryItem>.generate(
        1000,
        (index) => LibraryItem(
          sourceId: 'main',
          title: '文件 $index',
          url: 'https://www.lanzouw.com/i$index',
          shareUrl: 'https://www.lanzouw.com/i$index',
          size: '${index + 1} MB',
          time: '2026-07-14',
          isFolder: false,
        ),
        growable: false,
      );

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('compact-home-source-grid')),
        matching: find.text('主源'),
      ),
    );
    await tester.pumpAndSettle();

    final builtRows = find.byType(LibraryCompactGridTile).evaluate().length;
    expect(builtRows, greaterThan(0));
    expect(builtRows, lessThan(30), reason: '目录必须按视口惰性构建');
    expect(
      find.descendant(
        of: find.byKey(const Key('directory-scroll-view')),
        matching: find.byType(SliverGrid),
      ),
      findsOneWidget,
    );
    expect(find.text('文件 999'), findsNothing);

    await tester.drag(
      find.byKey(const Key('directory-scroll-view')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    final builtAfterScroll = find
        .byType(LibraryCompactGridTile)
        .evaluate()
        .length;
    expect(builtAfterScroll, greaterThan(0));
    expect(builtAfterScroll, lessThan(30), reason: '滚动后仍只能保留视口附近的网格项');
    expect(find.text('文件 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'wide source pane lazily navigates a 606 source catalog without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        LibraryShellApp.testHarness(
          config: manySourceConfig(606),
          core: FakeLibraryCore(),
          linkOpener: FakeLinkOpener(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(const Key('wide-source-list')), findsOneWidget);
      expect(find.byKey(const Key('wide-source-main')), findsOneWidget);
      expect(find.byKey(const Key('wide-source-source_605')), findsNothing);
      expect(find.byType(ListTile).evaluate().length, lessThan(40));
      expect(tester.takeException(), isNull);

      await tester.dragUntilVisible(
        find.byKey(const Key('wide-source-source_605')),
        find.descendant(
          of: find.byKey(const Key('wide-source-list')),
          matching: find.byType(Scrollable),
        ),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wide-source-source_605')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('insert motion is consumed once and does not restart on scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = List<LibraryItem>.generate(
      1000,
      (index) => LibraryItem(
        sourceId: 'main',
        title: '动画文件 $index',
        url: 'https://www.lanzouw.com/ianimation$index',
        shareUrl: 'https://www.lanzouw.com/ianimation$index',
        isFolder: false,
      ),
      growable: false,
    );
    final config = testConfig();
    final controller =
        LibraryController(config: config, core: FakeLibraryCore())
          ..selectedSource = config.sources.first
          ..items = items
          ..folder = LibraryFolder(
            sourceId: 'main',
            title: '动画目录',
            url: 'https://www.lanzouw.com/broot',
            items: items,
          )
          ..status = LibraryContentStatus.data;
    addTearDown(controller.dispose);
    final firstKey = Key('compact-library-item-${items.first.stableKey}');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
        home: Scaffold(
          body: LibraryDirectoryList(
            controller: controller,
            compactGrid: true,
            appearingKeys: {items.first.stableKey},
            onTapItem: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byKey(firstKey),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('directory-scroll-view')),
      const Offset(0, -1800),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(firstKey), findsNothing);

    await tester.drag(
      find.byKey(const Key('directory-scroll-view')),
      const Offset(0, 1800),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(firstKey), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(firstKey),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsNothing,
      reason: '离开并回到视口时不能重播插入动画',
    );
  });

  testWidgets('load-more keeps the existing scrollable and viewport offset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..rootHasMore = true
      ..rootItems = List<LibraryItem>.generate(
        80,
        (index) => LibraryItem(
          sourceId: 'main',
          title: '分页文件 $index',
          url: 'https://www.lanzouw.com/ipage$index',
          shareUrl: 'https://www.lanzouw.com/ipage$index',
          isFolder: false,
        ),
      )
      ..loadMoreCompleter = Completer<LibraryFolder>();

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-source-main')));
    await tester.pumpAndSettle();
    final scrollableFinder = find.descendant(
      of: find.byKey(const Key('directory-scroll-view')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('加载更多'),
      600,
      scrollable: scrollableFinder,
    );
    final beforeState = tester.state<ScrollableState>(scrollableFinder);
    final beforeOffset = beforeState.position.pixels;

    await tester.tap(find.text('加载更多'));
    await tester.pump();
    final duringState = tester.state<ScrollableState>(scrollableFinder);
    expect(identical(duringState, beforeState), isTrue);
    expect(duringState.position.pixels, moreOrLessEquals(beforeOffset));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    core.loadMoreCompleter!.complete(
      LibraryFolder(
        sourceId: 'main',
        title: '主源',
        url: 'https://www.lanzouw.com/broot',
        page: 2,
        items: List<LibraryItem>.generate(
          20,
          (index) => LibraryItem(
            sourceId: 'main',
            title: '新增文件 $index',
            url: 'https://www.lanzouw.com/inew$index',
            shareUrl: 'https://www.lanzouw.com/inew$index',
            isFolder: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final afterState = tester.state<ScrollableState>(scrollableFinder);
    expect(identical(afterState, beforeState), isTrue);
    expect(afterState.position.pixels, moreOrLessEquals(beforeOffset));
    expect(tester.takeException(), isNull);
  });

  testWidgets('near-bottom scrolling starts exactly one next-page request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..rootHasMore = true
      ..rootItems = List<LibraryItem>.generate(
        80,
        (index) => LibraryItem(
          sourceId: 'main',
          title: '自动分页文件 $index',
          url: 'https://www.lanzouw.com/iauto$index',
          shareUrl: 'https://www.lanzouw.com/iauto$index',
          isFolder: false,
        ),
      )
      ..loadMoreCompleter = Completer<LibraryFolder>();

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-source-main')));
    await tester.pumpAndSettle();
    final scrollableFinder = find.descendant(
      of: find.byKey(const Key('directory-scroll-view')),
      matching: find.byType(Scrollable),
    );

    await tester.scrollUntilVisible(
      find.text('加载更多'),
      600,
      scrollable: scrollableFinder,
    );
    await tester.pump();
    expect(core.browseCalls, hasLength(2));

    await tester.drag(scrollableFinder, const Offset(0, -180));
    await tester.pump();
    expect(core.browseCalls, hasLength(2), reason: '同一页的重复滚动信号必须单飞');

    core.loadMoreCompleter!.complete(
      const LibraryFolder(
        sourceId: 'main',
        title: '主源',
        url: 'https://www.lanzouw.com/broot',
        page: 2,
        items: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic pagination failure keeps rows and exposes retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..rootHasMore = true
      ..loadMoreFailure = const LibraryCoreFailure('rate_limited', '下一页暂时不可用')
      ..rootItems = List<LibraryItem>.generate(
        80,
        (index) => LibraryItem(
          sourceId: 'main',
          title: '失败分页文件 $index',
          url: 'https://www.lanzouw.com/ifailed$index',
          shareUrl: 'https://www.lanzouw.com/ifailed$index',
          isFolder: false,
        ),
      );

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-source-main')));
    await tester.pumpAndSettle();
    final scrollableFinder = find.descendant(
      of: find.byKey(const Key('directory-scroll-view')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('失败分页文件 78'),
      600,
      scrollable: scrollableFinder,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('directory-scroll-view')), findsOneWidget);
    expect(find.text('下一页暂时不可用'), findsOneWidget);
    expect(find.byKey(const Key('retry-load-more')), findsOneWidget);
    expect(core.browseCalls, hasLength(2));

    await tester.tap(find.byKey(const Key('retry-load-more')));
    await tester.pumpAndSettle();
    expect(core.browseCalls, hasLength(3));
    expect(find.text('下一页暂时不可用'), findsOneWidget);
  });

  testWidgets('supports keyboard focus, refresh and causal back navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore();

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);

    final browseCallsBeforeRefresh = core.browseCalls.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(core.browseCalls.length, browseCallsBeforeRefresh + 1);

    await tester.enterText(find.byType(SearchBar), '编辑器');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('没有匹配结果'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('示例文件'), findsOneWidget);
    expect(find.text('没有匹配结果'), findsNothing);

    final rowFocus = tester.widget<FocusableActionDetector>(
      find.descendant(
        of: find.byType(LibraryDirectoryRow).last,
        matching: find.byType(FocusableActionDetector),
      ),
    );
    expect(rowFocus.mouseCursor, SystemMouseCursors.click);
  });

  testWidgets('adapts sources, browsing, breadcrumbs and details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore();
    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试软件库'), findsOneWidget);
    expect(find.byKey(const Key('wide-source-pane')), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsWidgets);

    await tester.tap(find.text('工具'));
    await tester.pumpAndSettle();
    expect(
      core.browseCalls.last.shareUrl,
      'https://www.lanzouw.com/virtual-folder',
    );
    expect(find.text('工具'), findsWidgets);

    final selectedRow = tester.widget<LibraryDirectoryRow>(
      find.byType(LibraryDirectoryRow).last,
    );
    expect(selectedRow.item.title, '示例文件');
    await tester.tap(find.text('示例文件'));
    await tester.pumpAndSettle();
    expect(find.text('文件简介'), findsOneWidget);
    expect(find.text('用于验证详情的软件包'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '示例文件'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '用于验证详情的软件包'), findsOneWidget);
    expect(core.describeCalls, isEmpty);

    expect(find.widgetWithText(FilledButton, '下载'), findsNothing);
  });

  testWidgets('searches and exposes empty/error retry states', (tester) async {
    final core = FakeLibraryCore();
    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), '编辑器');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(core.searchQueries, ['编辑器']);
    expect(find.text('没有匹配结果'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    core.browseFailure = const LibraryCoreFailure(
      'network',
      '暂时无法连接',
      retriable: true,
    );
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法连接'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

    core.browseFailure = null;
    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pumpAndSettle();
    expect(find.text('示例文件'), findsOneWidget);
  });

  testWidgets('shows source progress and cancels a running native search', (
    tester,
  ) async {
    final core = SlowSearchLibraryCore();
    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), '工具');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 180));

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('已完成 1/2 个来源，找到 3 项'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '已完成 1/2 个来源，找到 3 项' &&
            widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, '取消搜索'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '取消搜索'));
    await tester.pumpAndSettle();

    expect(core.cancelledOperationId, core.searchOperationId);
    expect(core.forgottenOperationId, core.searchOperationId);
    expect(find.text('搜索已取消'), findsOneWidget);
  });

  testWidgets('progress and description updates never rebuild the shell root', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final config = testConfig();
    final core = SlowSearchLibraryCore()
      ..itemDescription = ''
      ..describeCompleter = Completer<LibraryDescribeResult>();
    var shellBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
        home: LibraryPage(
          config: config,
          core: core,
          linkOpener: FakeLinkOpener(),
          debugOnShellBuild: () => shellBuilds++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final stableBuildCount = shellBuilds;

    await tester.tap(find.byType(LibraryDirectoryRow).last);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('正在加载简介'), findsOneWidget);
    expect(shellBuilds, stableBuildCount);
    core.describeCompleter!.complete(
      const LibraryDescribeResult(description: '局部更新后的简介'),
    );
    await tester.pumpAndSettle();
    expect(find.text('局部更新后的简介'), findsOneWidget);
    expect(shellBuilds, stableBuildCount);

    await tester.enterText(find.byType(SearchBar), '性能');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('已完成 1/2 个来源，找到 3 项'), findsOneWidget);
    expect(shellBuilds, stableBuildCount);

    await tester.tap(find.widgetWithText(FilledButton, '取消搜索'));
    await tester.pumpAndSettle();
    expect(shellBuilds, stableBuildCount);
  });

  testWidgets('search polling rebuilds only the progress subtree', (
    tester,
  ) async {
    final config = testConfig();
    final core = SlowSearchLibraryCore();
    final controller = LibraryController(config: config, core: core);
    final searchController = TextEditingController();
    final searchFocusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(searchController.dispose);
    addTearDown(searchFocusNode.dispose);
    await controller.initialize();
    var paneBuilds = 0;
    var progressBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
        home: Scaffold(
          body: LibraryContentPane(
            controller: controller,
            searchController: searchController,
            searchFocusNode: searchFocusNode,
            showPersistentDetails: false,
            showSourceHeader: false,
            onShowTransientDetails: (_) {},
            debugOnPaneBuild: () => paneBuilds++,
            debugOnSearchProgressBuild: () => progressBuilds++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final search = controller.search('局部进度');
    await tester.pump();
    await tester.pump();
    expect(find.byType(LibrarySearchLoadingState), findsOneWidget);
    final paneBuildsAtSearchStart = paneBuilds;
    final progressBuildsAtSearchStart = progressBuilds;

    await tester.pump(const Duration(milliseconds: 180));
    expect(progressBuilds, greaterThan(progressBuildsAtSearchStart));
    expect(
      paneBuilds,
      paneBuildsAtSearchStart,
      reason: '进度轮询不得重建 breadcrumb/header/search/list 整列',
    );

    await controller.cancelSearch();
    await search;
    await tester.pumpAndSettle();
  });

  testWidgets('uses compact NavigationBar and zero-duration reduced motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          disableAnimations: true,
        ),
        child: LibraryShellApp.testHarness(
          config: testConfig(),
          core: FakeLibraryCore(),
          linkOpener: FakeLinkOpener(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navigation = tester.widget<NavigationBar>(
      find.byKey(const Key('compact-navigation-bar')),
    );
    expect(navigation.animationDuration, Duration.zero);
    expect(find.byKey(const Key('wide-source-pane')), findsNothing);
    expect(find.text('下载'), findsNothing);
    await tester.tap(find.byKey(const Key('home-source-main')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('compact-directory-grid')), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    for (final container in tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    )) {
      expect(container.duration, Duration.zero);
    }
  });

  testWidgets('opens the optional official site through the link abstraction', (
    tester,
  ) async {
    final opener = FakeLinkOpener();
    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(),
        core: FakeLibraryCore(),
        linkOpener: opener,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('官网'));
    await tester.pump();
    expect(opener.opened, ['https://example.invalid']);
  });

  testWidgets('feature flags remove search, download and descriptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(
          search: false,
          download: false,
          showDescription: false,
          officialUrl: '',
          publisher: '',
        ),
        core: FakeLibraryCore(),
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SearchBar), findsNothing);
    expect(find.byTooltip('官网'), findsNothing);
    await tester.tap(find.byType(LibraryDirectoryRow).last);
    await tester.pumpAndSettle();
    expect(find.text('文件简介'), findsNothing);
    expect(find.widgetWithText(FilledButton, '下载'), findsNothing);
    expect(find.text('下载'), findsNothing);
    expect(
      (tester.widget<LibraryShellApp>(find.byType(LibraryShellApp)).core
              as FakeLibraryCore)
          .describeCalls,
      isEmpty,
    );

    final guardedCore = FakeLibraryCore();
    final guardedController = LibraryController(
      config: testConfig(search: false, download: false),
      core: guardedCore,
    );
    addTearDown(guardedController.dispose);
    await guardedController.search('不会执行');
    await guardedController.downloadItem(
      const LibraryItem(
        sourceId: 'main',
        title: '不会下载',
        url: 'https://www.lanzouw.com/iguarded',
        shareUrl: 'https://www.lanzouw.com/iguarded',
        isFolder: false,
      ),
    );
    expect(guardedCore.searchQueries, isEmpty);
    expect(guardedCore.resolveCalls, isEmpty);
    expect(guardedController.detailError, isEmpty);
  });

  testWidgets('lazily loads an empty description only after file selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..itemDescription = ''
      ..describeCompleter = Completer<LibraryDescribeResult>();

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(password: 'private-value'),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    expect(core.describeCalls, isEmpty, reason: '目录页不得预取每个文件的简介');

    final lazyDescriptionRow = tester.widget<LibraryDirectoryRow>(
      find.byType(LibraryDirectoryRow).last,
    );
    expect(lazyDescriptionRow.item.title, '示例文件');
    await tester.tap(find.text('示例文件'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(core.describeCalls, hasLength(1));
    expect(core.describeCalls.single.password, 'private-value');
    expect(find.text('正在加载简介'), findsOneWidget);

    core.describeCompleter!.complete(
      const LibraryDescribeResult(description: '选择后加载的文件简介'),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择后加载的文件简介'), findsOneWidget);
    expect(find.text('正在加载简介'), findsNothing);
  });

  testWidgets('description errors never expose the source password', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeLibraryCore()
      ..itemDescription = ''
      ..describeFailure = const LibraryCoreFailure(
        'network',
        '请求 private-value 失败',
        retriable: true,
      );

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(password: 'private-value'),
        core: core,
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LibraryDirectoryRow).last);
    await tester.pumpAndSettle();

    expect(find.text('无法加载简介，请稍后重试'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
  });

  testWidgets(
    'uses a custom Material source and category dialog without dropdowns',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeLibraryCore();

      await tester.pumpWidget(
        LibraryShellApp.testHarness(
          config: uiDetailConfig(),
          core: core,
          linkOpener: FakeLinkOpener(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择来源'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library-source-picker-dialog')), findsOne);
      expect(find.byType(DropdownButton<dynamic>), findsNothing);
      expect(find.byKey(const Key('source-filter-all')), findsOne);
      expect(find.byKey(const Key('source-filter-recommended')), findsOne);
      expect(find.byKey(const Key('source-filter-searchable')), findsOne);
      expect(find.byKey(const Key('source-filter-directory')), findsOne);

      await tester.tap(find.byKey(const Key('source-filter-directory')));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('library-source-picker-dialog'));
      expect(
        find.descendant(of: dialog, matching: find.text('仅目录源')),
        findsOne,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('主源')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('source-picker-directory_only')));
      await tester.pumpAndSettle();
      expect(core.browseCalls.last.sourceId, 'directory_only');
      expect(
        find.byKey(const Key('library-source-picker-dialog')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'highlights a real search-result source and returns to the search path',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeLibraryCore()
        ..searchItems = [
          ...List<LibraryItem>.generate(
            18,
            (index) => LibraryItem(
              sourceId: 'main',
              title: '搜索占位项 $index',
              url: 'https://www.lanzoui.com/idummy$index',
              shareUrl: 'https://www.lanzoui.com/idummy$index',
              source: '主源',
              isFolder: false,
            ),
          ),
          const LibraryItem(
            sourceId: 'secondary',
            title: '来源跳转文件',
            url: 'https://www.lanzoui.com/isourcejump',
            shareUrl: 'https://www.lanzoui.com/isourcejump',
            source: '次源',
            isFolder: false,
          ),
          ...List<LibraryItem>.generate(
            6,
            (index) => LibraryItem(
              sourceId: 'main',
              title: '搜索尾项 $index',
              url: 'https://www.lanzoui.com/itail$index',
              shareUrl: 'https://www.lanzoui.com/itail$index',
              source: '主源',
              isFolder: false,
            ),
          ),
        ];

      await tester.pumpWidget(
        LibraryShellApp.testHarness(
          config: uiDetailConfig(),
          core: core,
          linkOpener: FakeLinkOpener(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('compact-home-search')),
        '编辑器',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      final provenance = find.byKey(
        const Key('search-result-source-secondary'),
      );
      final directory = find.byKey(const Key('directory-scroll-view'));
      await tester.scrollUntilVisible(
        provenance,
        420,
        scrollable: find.descendant(
          of: directory,
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      final searchOffsetBeforeSource = tester
          .widget<CustomScrollView>(directory)
          .controller!
          .offset;
      expect(searchOffsetBeforeSource, greaterThan(0));
      expect(provenance, findsOne);
      expect(
        tester
            .widget<Semantics>(
              find
                  .ancestor(of: provenance, matching: find.byType(Semantics))
                  .first,
            )
            .properties
            .button,
        isTrue,
      );

      final delayedSourceBrowse = Completer<LibraryFolder>();
      core.browseCompleter = delayedSourceBrowse;
      await tester.tap(provenance);
      await tester.pump(const Duration(milliseconds: 500));
      expect(core.browseCalls.last.sourceId, 'secondary');
      expect(find.text('次源'), findsWidgets);
      expect(find.text('来源跳转文件'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(core.searchQueries, ['编辑器'], reason: '返回搜索结果必须恢复原会话，不能重新请求全部来源');
      expect(find.text('来源跳转文件'), findsOne);
      expect(find.byKey(const Key('search-result-source-secondary')), findsOne);
      expect(
        tester.widget<CustomScrollView>(directory).controller!.offset,
        closeTo(searchOffsetBeforeSource, 1),
        reason: '返回后必须恢复搜索结果的原滚动位置',
      );

      delayedSourceBrowse.complete(
        const LibraryFolder(
          sourceId: 'secondary',
          title: '迟到的来源目录',
          url: 'https://www.lanzoui.com/bsecondary',
          items: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('来源跳转文件'), findsOne);
      expect(find.text('迟到的来源目录'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('share action exposes two real copy methods in a custom dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = (call.arguments as Map).cast<Object?, Object?>();
          clipboardWrites.add(arguments['text']! as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      LibraryShellApp.testHarness(
        config: testConfig(password: 'access'),
        core: FakeLibraryCore(),
        linkOpener: FakeLinkOpener(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('示例文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-share-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-share-dialog')), findsOne);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('分享文本'), findsOne);
    expect(find.text('可导入软件库来源'), findsOne);
    await tester.tap(find.byKey(const Key('share-method-text')));
    await tester.pumpAndSettle();
    expect(clipboardWrites.single, contains('示例文件'));
    expect(clipboardWrites.single, contains('https://www.lanzouw.com/ifile'));

    await tester.tap(find.byKey(const Key('detail-share-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-method-importable-source')));
    await tester.pumpAndSettle();
    expect(
      clipboardWrites.last,
      'https://www.lanzouw.com/ifile access',
      reason: '可导入来源必须保持“链接 密码”且不夹带标题',
    );
    expect(find.text('可导入来源已复制'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow high-scale layout switches fixed grids to unclipped lazy lists',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final config = uiDetailConfig();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLibraryTheme(config.branding.seedColor, Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.fromLTRB(18, 24, 18, 28),
              viewPadding: const EdgeInsets.fromLTRB(18, 24, 18, 28),
            ),
            child: child!,
          ),
          home: LibraryPage(
            config: config,
            core: FakeLibraryCore(),
            linkOpener: FakeLinkOpener(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('compact-home-source-list')), findsOne);
      expect(find.byKey(const Key('compact-home-source-grid')), findsNothing);
      await tester.tap(find.byKey(const Key('home-source-main')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('compact-directory-list')), findsOne);
      expect(find.byType(LibraryDirectoryRow), findsWidgets);
      expect(find.byKey(const Key('compact-navigation-bar')), findsOne);
      await tester.tap(find.byTooltip('选择来源'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library-source-picker-dialog')), findsOne);
      expect(tester.takeException(), isNull);
    },
  );
}

LibraryConfig testConfig({
  bool browse = true,
  bool search = true,
  bool download = false,
  bool showDescription = true,
  String officialUrl = 'https://example.invalid',
  String publisher = '测试维护者',
  String password = '',
}) => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'test_library',
    'displayName': '测试软件库',
    'applicationId': 'cc.example.testlibrary',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'test_library',
  },
  'branding': {
    'seedColor': '#2563EB',
    'themeMode': 'light',
    'officialUrl': officialUrl,
    'publisher': publisher,
    'logoAsset': 'assets/runtime/logo.png',
  },
  'sources': [
    {
      'sourceId': 'main',
      'title': '主源',
      'shareUrl': 'https://www.lanzouw.com/broot',
      'password': password,
      'searchable': true,
      'recommended': true,
    },
  ],
  'features': {
    'browse': browse,
    'search': search,
    'download': download,
    'showDescription': showDescription,
  },
});

LibraryConfig manySourceConfig(int count, {bool download = false}) =>
    LibraryConfig.fromJson({
      'schemaVersion': 1,
      'identity': {
        'projectId': 'large_library',
        'displayName': '大目录软件库',
        'applicationId': 'cc.example.largelibrary',
        'versionName': '1.0.0',
        'versionCode': 1,
        'windowsExeName': 'large_library',
      },
      'branding': {
        'seedColor': '#2563EB',
        'themeMode': 'light',
        'officialUrl': '',
        'publisher': '测试维护者',
        'logoAsset': 'assets/runtime/logo.png',
      },
      'sources': List<Object?>.generate(count, (index) {
        final id = index == 0 ? 'main' : 'source_$index';
        return {
          'sourceId': id,
          'title': '软件源 $index',
          'shareUrl': 'https://www.lanzouw.com/bsource$index',
          'password': '',
          'searchable': true,
          'recommended': index == 0,
        };
      }, growable: false),
      'features': {
        'browse': true,
        'search': true,
        'download': download,
        'showDescription': true,
      },
    });

LibraryConfig uiDetailConfig() => LibraryConfig.fromJson({
  'schemaVersion': 1,
  'identity': {
    'projectId': 'ui_details_library',
    'displayName': '界面细节软件库',
    'applicationId': 'cc.example.uidetails',
    'versionName': '1.0.0',
    'versionCode': 1,
    'windowsExeName': 'ui_details_library',
  },
  'branding': {
    'seedColor': '#6750A4',
    'themeMode': 'light',
    'officialUrl': '',
    'publisher': '测试维护者',
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
    {
      'sourceId': 'secondary',
      'title': '次源',
      'shareUrl': 'https://www.lanzoui.com/bsecondary',
      'password': '',
      'searchable': true,
      'recommended': false,
    },
    {
      'sourceId': 'directory_only',
      'title': '仅目录源',
      'shareUrl': 'https://directory.lanzouw.com/bdirectory',
      'password': '',
      'searchable': false,
      'recommended': false,
    },
  ],
  'features': {
    'browse': true,
    'search': true,
    'download': false,
    'showDescription': true,
  },
});

class FakeLibraryCore implements LibraryCore {
  final List<BrowseInvocation> browseCalls = [];
  final List<String> searchQueries = [];
  final List<String> resolveCalls = [];
  final List<DescribeInvocation> describeCalls = [];
  LibraryCoreFailure? browseFailure;
  LibraryCoreFailure? loadMoreFailure;
  LibraryCoreFailure? describeFailure;
  Completer<LibraryFolder>? browseCompleter;
  Completer<LibraryFolder>? loadMoreCompleter;
  Completer<LibraryDescribeResult>? describeCompleter;
  List<LibraryItem>? rootItems;
  List<LibraryItem> searchItems = const [];
  bool rootHasMore = false;
  String itemDescription = '用于验证详情的软件包';
  String folderPublisher = '';
  String folderDescription = '';

  @override
  Future<LibraryProbeResult> probe(LibrarySource source) async =>
      const LibraryProbeResult(
        source: LibraryProbeSource(
          sourceId: 'main',
          title: '主源',
          shareUrl: 'https://www.lanzouw.com/broot',
          searchable: true,
        ),
        folder: LibraryFolder(
          sourceId: 'main',
          title: '主源',
          url: 'https://www.lanzouw.com/broot',
          items: [],
        ),
      );

  @override
  Future<LibraryFolder> browse({
    required String sourceId,
    required String shareUrl,
    String password = '',
    int page = 1,
    bool refresh = false,
  }) async {
    browseCalls.add(BrowseInvocation(sourceId, shareUrl));
    if (browseFailure case final failure?) throw failure;
    if (page > 1) {
      if (loadMoreFailure case final failure?) throw failure;
    }
    final nextPageCompleter = loadMoreCompleter;
    if (page > 1 && nextPageCompleter != null) return nextPageCompleter.future;
    if (browseCompleter case final completer?) return completer.future;
    if (shareUrl.endsWith('virtual-folder')) {
      return LibraryFolder(
        sourceId: 'main',
        title: '工具',
        url: 'https://www.lanzouw.com/virtual-folder',
        items: [
          LibraryItem(
            sourceId: 'main',
            title: '示例文件',
            url: 'https://www.lanzouw.com/ifile',
            shareUrl: 'https://www.lanzouw.com/ifile',
            isFolder: false,
            description: itemDescription,
            size: '12 MB',
          ),
        ],
      );
    }
    return LibraryFolder(
      sourceId: 'main',
      title: '主源',
      url: 'https://www.lanzouw.com/broot',
      page: 1,
      hasMore: rootHasMore,
      publisher: folderPublisher,
      description: folderDescription,
      items:
          rootItems ??
          [
            const LibraryItem(
              sourceId: 'main',
              title: '工具',
              url: 'https://www.lanzouw.com/virtual-folder',
              shareUrl: 'https://www.lanzouw.com/broot',
              isFolder: true,
            ),
            LibraryItem(
              sourceId: 'main',
              title: '示例文件',
              url: 'https://www.lanzouw.com/ifile',
              shareUrl: 'https://www.lanzouw.com/ifile',
              isFolder: false,
              description: itemDescription,
            ),
          ],
    );
  }

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) async {
    searchQueries.add(query);
    return LibrarySearchResult(items: searchItems);
  }

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
  }) async {
    resolveCalls.add(shareUrl);
    return const LibraryResolveResult(
      url: 'https://download.invalid/file.zip',
      fileName: 'file.zip',
    );
  }

  @override
  Future<LibraryDescribeResult> describe({
    required String sourceId,
    required String shareUrl,
    String password = '',
  }) async {
    describeCalls.add(DescribeInvocation(sourceId, shareUrl, password));
    if (describeFailure case final failure?) throw failure;
    final completer = describeCompleter;
    if (completer != null) return completer.future;
    return const LibraryDescribeResult(description: '选择后加载的文件简介');
  }
}

class SlowSearchLibraryCore extends FakeLibraryCore
    implements LibraryOperationCore {
  final Completer<LibrarySearchResult> _searchCompleter = Completer();
  String? searchOperationId;
  String? cancelledOperationId;
  String? forgottenOperationId;

  @override
  Future<LibrarySearchResult> search({
    required String query,
    required List<LibrarySource> sources,
    LibrarySearchOptions options = const LibrarySearchOptions(),
    String? operationId,
  }) {
    searchQueries.add(query);
    searchOperationId = operationId;
    return _searchCompleter.future;
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async =>
      LibraryOperationStatus(
        operationId: operationId,
        kind: 'library_search',
        state: LibraryOperationState.running,
        completedUnits: 1,
        totalUnits: 2,
        bytesTransferred: 0,
        totalBytes: 0,
        itemsFound: 3,
      );

  @override
  Future<void> cancelOperation(String operationId) async {
    cancelledOperationId = operationId;
    if (!_searchCompleter.isCompleted) {
      _searchCompleter.completeError(
        const LibraryCoreFailure('cancelled', '搜索已取消'),
      );
    }
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    forgottenOperationId = operationId;
  }
}

class BrowseInvocation {
  const BrowseInvocation(this.sourceId, this.shareUrl);

  final String sourceId;
  final String shareUrl;
}

class DescribeInvocation {
  const DescribeInvocation(this.sourceId, this.shareUrl, this.password);

  final String sourceId;
  final String shareUrl;
  final String password;
}

class FakeLinkOpener implements LinkOpener {
  final List<String> opened = [];

  @override
  Future<void> open(String url) async => opened.add(url);
}
