import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart';

void main() {
  testWidgets('606 sources stay lazy and category chooser is a custom dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final core = _PageRegistryCore();

    await tester.pumpWidget(MaterialApp(home: SourceManagerPage(core: core)));
    await tester.pumpAndSettle();

    expect(find.text('共 606 个来源'), findsOneWidget);
    expect(find.byKey(const Key('source-registry-list')), findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(30));

    await tester.tap(find.byKey(const Key('source-category-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-category-dialog')), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.tap(find.byKey(const Key('source-category-tools')));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('source-row-source-0')));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
  });
}

class _PageRegistryCore implements SourceRegistryCore {
  List<SourceRegistrySource> get sources => List.generate(
    606,
    (index) => SourceRegistrySource(
      id: 'source-$index',
      kind: index == 605
          ? SourceRegistrySourceKind.singleSoftware
          : SourceRegistrySourceKind.official,
      title: '来源 $index',
      publisher: '',
      description: '',
      avatarUrl: '',
      shareUrl: 'https://www.lanzouw.com/source-$index',
      searchable: true,
      childDirectory: false,
      originPath: '',
      originUrl: '',
      memberCount: 0,
      builtIn: true,
    ),
  );

  @override
  Future<SourceRegistrySnapshot> sourceRegistrySnapshot() async =>
      const SourceRegistrySnapshot(
        generation: 1,
        baselineRevision: 'catalog-v1',
        baselineCount: 606,
        userCount: 0,
        mergedCount: 606,
        categories: [
          SourceRegistryCategory(id: 'tools', title: '工具', sourceIds: []),
        ],
        userSources: [],
      );

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
  }) async {
    final offset = cursor.isEmpty ? 0 : int.parse(cursor);
    final end = (offset + limit).clamp(0, sources.length);
    return SourceRegistryPage(
      generation: 1,
      total: sources.length,
      nextCursor: end < sources.length ? '$end' : '',
      hasMore: end < sources.length,
      sources: sources.sublist(offset, end),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
