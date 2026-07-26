import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/library_preview.dart';

void main() {
  group('SourceRegistryController Rust contract', () {
    test(
      'forwards query category kind and nullable Rust-side filters',
      () async {
        final core = _RecordingReadCore(total: 606);
        final controller = SourceRegistryController(core: core);

        await controller.initialize();
        await controller.applyFilter(
          const SourceRegistryFilter(
            kind: SourceRegistrySourceKind.composite,
            searchable: true,
            childDirectory: false,
            builtIn: false,
          ),
        );
        controller.updateQuery('  工具  ');
        await Future<void>.delayed(const Duration(milliseconds: 320));
        await controller.selectCategory('tools');

        final call = core.pageCalls.last;
        expect(call.query, '工具');
        expect(call.categoryId, 'tools');
        expect(call.kind, 'composite');
        expect(call.searchable, isTrue);
        expect(call.childDirectory, isFalse);
        expect(call.builtIn, isFalse);
        controller.dispose();
      },
    );

    test(
      'pages 600+ sources in bounded batches without duplicate admission',
      () async {
        final core = _RecordingReadCore(total: 606);
        final controller = SourceRegistryController(core: core);

        await controller.initialize();
        expect(controller.sources, hasLength(100));
        expect(core.pageCalls.single.limit, 100);

        while (controller.hasMore) {
          await Future.wait([controller.loadMore(), controller.loadMore()]);
        }

        expect(controller.sources, hasLength(606));
        expect(
          controller.sources.map((item) => item.id).toSet(),
          hasLength(606),
        );
        expect(core.pageCalls, hasLength(7));
        expect(core.pageCalls.every((call) => call.limit == 100), isTrue);
        controller.dispose();
      },
    );

    test(
      'raw import preview keeps category and commits only the opaque id',
      () async {
        final core = _RecordingFullCore(total: 1);
        final controller = SourceRegistryController(core: core);
        await controller.initialize();

        final preview = await controller.previewRawImport(
          const SourceRegistryRawImportDraft(
            rawText: 'https://www.lanzouw.com/b01 code',
            categoryId: 'tools',
          ),
        );
        expect(preview?.previewId, 'preview-opaque');
        expect(core.previewRawText, 'https://www.lanzouw.com/b01 code');
        expect(core.previewCategoryId, 'tools');

        final result = await controller.commitRawImport(preview!);
        expect(result?.added, 1);
        expect(core.committedPreviewId, 'preview-opaque');
        expect(core.committedGeneration, preview.generation);
        controller.dispose();
      },
    );

    test(
      'credential export uses the Rust confirmation gate verbatim',
      () async {
        final core = _RecordingFullCore(total: 1);
        final controller = SourceRegistryController(core: core);
        await controller.initialize();
        controller.toggleSelection(controller.sources.single);

        await controller.exportSelected(
          r'D:\rules.json',
          includeCredentials: true,
        );

        expect(core.exportIncludedCredentials, isTrue);
        expect(core.exportCredentialConfirmation, 'export-source-access-codes');
        controller.dispose();
      },
    );
  });

  group('SourceRegistry DTOs', () {
    test(
      'update draft distinguishes preserving and clearing an access code',
      () {
        const preserve = SourceRegistrySourceUpdateDraft(
          sourceId: 'user:1',
          title: '工具',
          searchable: true,
        );
        const clear = SourceRegistrySourceUpdateDraft(
          sourceId: 'user:1',
          title: '工具',
          searchable: true,
          accessCode: '',
        );

        expect(preserve.toJson(), isNot(contains('accessCode')));
        expect(clear.toJson()['accessCode'], '');
      },
    );

    test('delete result is strict and reports removed hidden and missing', () {
      final result = SourceRegistryDeleteResult.fromJson(const {
        'generation': 7,
        'removed': 2,
        'hidden': 1,
        'missing': 0,
      });

      expect(result.generation, 7);
      expect(result.removed, 2);
      expect(result.hidden, 1);
      expect(result.missing, 0);
      expect(
        () => SourceRegistryDeleteResult.fromJson(const {
          'generation': 7,
          'removed': 2,
          'hidden': 1,
          'missing': 0,
          'password': 'must-not-cross-ffi',
        }),
        throwsFormatException,
      );
    });
  });
}

class _PageCall {
  const _PageCall({
    required this.cursor,
    required this.limit,
    required this.query,
    required this.categoryId,
    required this.kind,
    required this.searchable,
    required this.childDirectory,
    required this.builtIn,
  });

  final String cursor;
  final int limit;
  final String query;
  final String categoryId;
  final String kind;
  final bool? searchable;
  final bool? childDirectory;
  final bool? builtIn;
}

class _RecordingReadCore implements SourceRegistryCore {
  _RecordingReadCore({required this.total});

  final int total;
  final List<_PageCall> pageCalls = [];

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
    pageCalls.add(
      _PageCall(
        cursor: cursor,
        limit: limit,
        query: query,
        categoryId: categoryId,
        kind: kind,
        searchable: searchable,
        childDirectory: childDirectory,
        builtIn: builtIn,
      ),
    );
    final offset = cursor.isEmpty ? 0 : int.parse(cursor);
    final end = (offset + limit).clamp(0, total);
    return SourceRegistryPage(
      generation: 0,
      total: total,
      nextCursor: end < total ? '$end' : '',
      hasMore: end < total,
      sources: List.generate(
        end - offset,
        (index) => _source(offset + index),
        growable: false,
      ),
    );
  }

  @override
  Future<SourceRegistrySnapshot> sourceRegistrySnapshot() async =>
      SourceRegistrySnapshot(
        generation: 0,
        baselineRevision: 'A' * 64,
        baselineCount: total,
        userCount: 0,
        mergedCount: total,
        categories: const [
          SourceRegistryCategory(id: 'tools', title: '工具', sourceIds: []),
        ],
        userSources: const [],
      );
}

class _RecordingFullCore extends _RecordingReadCore
    implements SourceRegistryFullCore {
  _RecordingFullCore({required super.total});

  String previewRawText = '';
  String previewCategoryId = '';
  String committedPreviewId = '';
  int committedGeneration = -1;
  bool exportIncludedCredentials = false;
  String exportCredentialConfirmation = '';

  @override
  Future<SourceRegistryImportPreview> sourceRegistryImportPreview({
    required int expectedGeneration,
    required String rawText,
    String categoryId = '',
  }) async {
    previewRawText = rawText;
    previewCategoryId = categoryId;
    return const SourceRegistryImportPreview(
      generation: 0,
      previewId: 'preview-opaque',
      valid: [
        SourceRegistryPreviewValid(
          line: 1,
          title: '工具',
          shareUrl: 'https://www.lanzouw.com/b01',
          requiresCode: true,
          categoryId: 'tools',
        ),
      ],
      duplicates: [],
      invalid: [],
    );
  }

  @override
  Future<SourceRegistryImportResult> sourceRegistryCommitImportPreview({
    required int expectedGeneration,
    required String previewId,
  }) async {
    committedGeneration = expectedGeneration;
    committedPreviewId = previewId;
    return const SourceRegistryImportResult(
      generation: 1,
      added: 1,
      duplicates: 0,
      invalid: 0,
    );
  }

  @override
  Future<SourceRegistryImportResult> sourceRegistryBatchImport({
    required int expectedGeneration,
    required List<SourceRegistrySourceDraft> sources,
  }) async => SourceRegistryImportResult(
    generation: expectedGeneration + 1,
    added: sources.length,
    duplicates: 0,
    invalid: 0,
  );

  @override
  Future<SourceRegistryMutation> sourceRegistryRetest({
    required int expectedGeneration,
    required List<String> sourceIds,
  }) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryMutation> sourceRegistryUpdateSource({
    required int expectedGeneration,
    required SourceRegistrySourceUpdateDraft update,
  }) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryDeleteResult> sourceRegistryDeleteSources({
    required int expectedGeneration,
    required List<String> sourceIds,
  }) async => SourceRegistryDeleteResult(
    generation: expectedGeneration + 1,
    removed: sourceIds.length,
    hidden: 0,
    missing: 0,
  );

  @override
  Future<SourceRegistryMutation> sourceRegistryUpsertCategory({
    required int expectedGeneration,
    required SourceRegistryCategoryDraft category,
  }) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryMutation> sourceRegistryDeleteCategory({
    required int expectedGeneration,
    required String categoryId,
  }) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryMutation> sourceRegistrySetCategoryMembers({
    required int expectedGeneration,
    required String categoryId,
    required List<String> sourceIds,
  }) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryCompositeMutation> sourceRegistryUpsertComposite({
    required int expectedGeneration,
    required SourceRegistryCompositeDraft composite,
  }) async => SourceRegistryCompositeMutation(
    generation: expectedGeneration + 1,
    sourceId: 'local:bundle',
  );

  @override
  Future<SourceRegistryMutation> sourceRegistryDeleteComposite({
    required int expectedGeneration,
    required String sourceId,
  }) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryImportResult> sourceRegistryImportRules({
    required int expectedGeneration,
    required String sourcePath,
  }) async => SourceRegistryImportResult(
    generation: expectedGeneration + 1,
    added: 0,
    duplicates: 0,
    invalid: 0,
  );

  @override
  Future<SourceRegistryImportResult> sourceRegistryFetchImportRules({
    required int expectedGeneration,
    required String rulesUrl,
  }) async => SourceRegistryImportResult(
    generation: expectedGeneration + 1,
    added: 0,
    duplicates: 0,
    invalid: 0,
  );

  @override
  Future<SourceRegistryExportResult> sourceRegistryExportRules({
    required int expectedGeneration,
    required String destinationPath,
    List<String> sourceIds = const [],
    bool includeCredentials = false,
    String credentialConfirmation = '',
  }) async {
    exportIncludedCredentials = includeCredentials;
    exportCredentialConfirmation = credentialConfirmation;
    return SourceRegistryExportResult(
      generation: expectedGeneration,
      count: sourceIds.length,
      bytesWritten: 1,
      sha256: 'A' * 64,
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryRestoreBackup(
    int expectedGeneration,
  ) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryMutation> sourceRegistryRestoreOfficial(
    int expectedGeneration,
  ) async => SourceRegistryMutation(generation: expectedGeneration + 1);

  @override
  Future<SourceRegistryMutation> sourceRegistryReset(
    int expectedGeneration,
  ) async => SourceRegistryMutation(generation: expectedGeneration + 1);
}

SourceRegistrySource _source(int index) => SourceRegistrySource(
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
);
