import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart';

void main() {
  test('loads a 606 source registry lazily in bounded pages', () async {
    final core = _RegistryCore(606);
    final controller = SourceRegistryController(core: core);
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(controller.status, SourceRegistryStatus.data);
    expect(controller.total, 606);
    expect(controller.sources, hasLength(100));
    expect(controller.hasMore, isTrue);
    expect(core.pageCalls, 1);

    await controller.loadMore();
    expect(controller.sources, hasLength(200));
    expect(core.pageCalls, 2);
  });

  test(
    'selection and category mutation use the current Rust generation',
    () async {
      final core = _RegistryCore(606);
      final controller = SourceRegistryController(core: core);
      addTearDown(controller.dispose);
      await controller.initialize();

      controller.toggleSelection(controller.sources.first);
      expect(controller.selectedIds, hasLength(1));

      final result = await controller.upsertCategory(
        SourceRegistryCategoryDraft(
          id: 'tools',
          title: '工具',
          sourceIds: controller.selectedIds.toList(),
        ),
      );
      expect(result?.generation, 8);
      expect(core.lastExpectedGeneration, 7);
    },
  );
}

class _RegistryCore implements SourceRegistryCore, SourceRegistryCategoryCore {
  _RegistryCore(this.count);

  final int count;
  int generation = 7;
  int pageCalls = 0;
  int? lastExpectedGeneration;

  List<SourceRegistrySource> get sources => List.generate(
    count,
    (index) => SourceRegistrySource(
      id: 'source-$index',
      kind: SourceRegistrySourceKind.official,
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
      SourceRegistrySnapshot(
        generation: generation,
        baselineRevision: 'catalog-v1',
        baselineCount: count,
        userCount: 0,
        mergedCount: count,
        categories: const [
          SourceRegistryCategory(id: 'tools', title: '工具', sourceIds: []),
        ],
        userSources: const [],
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
    pageCalls++;
    final offset = cursor.isEmpty ? 0 : int.parse(cursor);
    final visible = sources
        .where((source) => query.isEmpty || source.title.contains(query))
        .toList(growable: false);
    final end = (offset + limit).clamp(0, visible.length);
    return SourceRegistryPage(
      generation: generation,
      total: visible.length,
      nextCursor: end < visible.length ? '$end' : '',
      hasMore: end < visible.length,
      sources: visible.sublist(offset, end),
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryUpsertCategory({
    required int expectedGeneration,
    required SourceRegistryCategoryDraft category,
  }) async {
    lastExpectedGeneration = expectedGeneration;
    generation++;
    return SourceRegistryMutation(generation: generation);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
