import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';
import 'package:lanzouyou/pages/settings/lanzou_settings_page.dart';

void main() {
  testWidgets('shows only Rust-confirmed capabilities as ordinary list rows', (
    tester,
  ) async {
    var imports = 0;
    var searchSettings = 0;
    final controller = LanzouSettingsController(
      catalog: _SettingsCore(),
      capabilities: const LanzouSettingsCapabilities(
        importSources: true,
        exportSources: false,
        searchBehavior: true,
      ),
      actions: LanzouSettingsActions(
        importSources: () async => imports++,
        openSearchBehavior: () async => searchSettings++,
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: LanzouSettingsPage(
          controller: controller,
          disposeController: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('蓝奏'), findsOneWidget);
    expect(find.text('12 个官方来源 · 3 个合集'), findsOneWidget);
    expect(find.text('导入来源'), findsOneWidget);
    expect(find.text('导出来源'), findsNothing);
    expect(find.text('搜索行为'), findsOneWidget);
    expect(find.text('下载行为'), findsNothing);
    expect(find.byType(Card), findsNothing);

    await tester.tap(find.text('导入来源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索行为'));
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(searchSettings, 1);
  });

  testWidgets('reset is confirmed and embedded mode omits a nested scaffold', (
    tester,
  ) async {
    var resets = 0;
    final controller = LanzouSettingsController(
      catalog: _SettingsCore(),
      capabilities: const LanzouSettingsCapabilities(resetSources: true),
      actions: LanzouSettingsActions(resetSources: () async => resets++),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LanzouSettingsPage(
            controller: controller,
            embedded: true,
            disposeController: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Scaffold), findsOneWidget);

    await tester.tap(find.text('恢复默认来源'));
    await tester.pumpAndSettle();
    expect(find.text('恢复默认来源？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-reset-lanzou-sources')));
    await tester.pumpAndSettle();
    expect(resets, 1);
  });

  testWidgets(
    'production capability set shows only summary and account entry',
    (tester) async {
      final controller = LanzouSettingsController(
        catalog: _SettingsCore(),
        capabilities: const LanzouSettingsCapabilities(),
        actions: const LanzouSettingsActions(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: LanzouSettingsPage(
            controller: controller,
            disposeController: false,
            accountContentBuilder: (_) => const Text('真实账号能力'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('12 个官方来源 · 3 个合集'), findsOneWidget);
      expect(find.byKey(const Key('lanzou-account-settings')), findsOneWidget);
      expect(find.text('导入来源'), findsNothing);
      expect(find.text('搜索行为'), findsNothing);
      expect(find.text('下载行为'), findsNothing);
      expect(find.byType(Card), findsNothing);
    },
  );

  testWidgets('wide settings keeps overview appearance and account as panes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = LanzouSettingsController(
      catalog: _SettingsCore(),
      capabilities: const LanzouSettingsCapabilities(),
      actions: const LanzouSettingsActions(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: LanzouSettingsPage(
          controller: controller,
          disposeController: false,
          appearanceContentBuilder: (_) => const Text('真实外观设置'),
          accountContentBuilder: (_) => const Text('真实账号能力'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('lanzou-settings-wide-master-detail')),
      findsOneWidget,
    );
    expect(find.text('来源概览'), findsWidgets);

    await tester.tap(find.byKey(const Key('lanzou-appearance-settings')));
    await tester.pumpAndSettle();
    expect(find.text('真实外观设置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('lanzou-account-settings')));
    await tester.pumpAndSettle();
    expect(find.text('真实账号能力'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });
}

class _SettingsCore implements PublicLibraryCatalogCore {
  @override
  Future<PublicLibraryCatalogSummary> catalogSummary() async =>
      const PublicLibraryCatalogSummary(
        revision: 'revision-1',
        officialCount: 12,
        compositeCount: 3,
        nodeCount: 20,
        searchableCount: 10,
      );

  @override
  Future<PublicLibraryCatalogPage> catalogPage({
    String parentId = '',
    String categoryId = 'all',
    String query = '',
    String cursor = '',
    int limit = 100,
  }) async => const PublicLibraryCatalogPage(
    revision: 'revision-1',
    total: 0,
    nextCursor: '',
    hasMore: false,
    nodes: [],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
