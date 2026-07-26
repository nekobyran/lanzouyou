import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart';

void main() {
  testWidgets('read-only core does not expose mutation actions', (
    tester,
  ) async {
    final core = _ReadOnlyCore();
    await tester.pumpWidget(_host(core: core));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('source-registry-list')), findsOneWidget);
    expect(find.byKey(const Key('source-add-fab')), findsNothing);
    expect(find.byKey(const Key('source-actions-menu')), findsNothing);
    expect(find.text('添加来源'), findsNothing);
  });

  testWidgets('narrow high-scale layout keeps filters and lazy list usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: _host(core: _ReadOnlyCore()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('source-search-field')), findsOneWidget);
    expect(find.byKey(const Key('source-kind-filter')), findsOneWidget);
    expect(find.byKey(const Key('source-registry-list')), findsOneWidget);
  });

  testWidgets('full Rust capabilities expose real management entrances', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        core: _CapabilityCore(),
        pickImportPath: () async => r'D:\rules.json',
        pickExportPath: () async => r'D:\export.json',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-actions-menu')));
    await tester.pumpAndSettle();
    expect(find.text('添加来源'), findsOneWidget);
    expect(find.text('新建合集'), findsOneWidget);
    expect(find.text('新建分类'), findsOneWidget);
    expect(find.text('管理分类'), findsOneWidget);
    expect(find.text('粘贴导入来源'), findsOneWidget);
    expect(find.text('从文件导入规则'), findsOneWidget);
    expect(find.text('从网址导入规则'), findsOneWidget);
    expect(find.text('导出规则'), findsOneWidget);
    expect(find.text('恢复官方来源'), findsOneWidget);
    expect(find.text('重置全部来源设置'), findsOneWidget);

    await tester.tapAt(const Offset(8, 700));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const Key('source-row-user-source')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('重新测试'), findsOneWidget);
    await tester.tap(find.byTooltip('更多所选操作'));
    await tester.pumpAndSettle();
    expect(find.text('编辑来源'), findsOneWidget);
    expect(find.text('加入分类'), findsOneWidget);
    expect(find.text('删除所选来源'), findsOneWidget);
  });
}

Widget _host({
  required SourceRegistryCore core,
  SourceRegistryPathPicker? pickImportPath,
  SourceRegistryPathPicker? pickExportPath,
}) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: SourceManagerPage(
    core: core,
    pickImportPath: pickImportPath,
    pickExportPath: pickExportPath,
  ),
);

class _ReadOnlyCore implements SourceRegistryCore {
  @override
  Future<SourceRegistryPage> sourceRegistryPage({
    String cursor = '',
    int limit = 100,
    String query = '',
    String categoryId = 'all',
    String kind = 'all',
    bool? searchable,
    bool? childDirectory,
    bool? builtIn,
  }) async => SourceRegistryPage(
    generation: 0,
    total: 606,
    nextCursor: '100',
    hasMore: true,
    sources: List.generate(
      100,
      (index) => SourceRegistrySource(
        id: 'source-$index',
        kind: SourceRegistrySourceKind.official,
        title: '来源 $index',
        publisher: '',
        description: '',
        avatarUrl: '',
        shareUrl: 'https://www.lanzouw.com/b$index',
        searchable: true,
        childDirectory: false,
        originPath: '',
        originUrl: '',
        memberCount: 0,
        builtIn: true,
      ),
      growable: false,
    ),
  );

  @override
  Future<SourceRegistrySnapshot> sourceRegistrySnapshot() async =>
      const SourceRegistrySnapshot(
        generation: 0,
        baselineRevision:
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        baselineCount: 606,
        userCount: 0,
        mergedCount: 606,
        categories: [
          SourceRegistryCategory(id: 'tools', title: '工具', sourceIds: []),
        ],
        userSources: [],
      );
}

class _CapabilityCore extends _ReadOnlyCore implements SourceRegistryFullCore {
  @override
  Future<SourceRegistryPage> sourceRegistryPage({
    String cursor = '',
    int limit = 100,
    String query = '',
    String categoryId = 'all',
    String kind = 'all',
    bool? searchable,
    bool? childDirectory,
    bool? builtIn,
  }) async => const SourceRegistryPage(
    generation: 0,
    total: 1,
    nextCursor: '',
    hasMore: false,
    sources: [
      SourceRegistrySource(
        id: 'user-source',
        kind: SourceRegistrySourceKind.official,
        title: '自定义来源',
        publisher: '',
        description: '',
        avatarUrl: '',
        shareUrl: 'https://www.lanzouw.com/user-source',
        searchable: true,
        childDirectory: false,
        originPath: '',
        originUrl: '',
        memberCount: 0,
        builtIn: false,
      ),
    ],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
