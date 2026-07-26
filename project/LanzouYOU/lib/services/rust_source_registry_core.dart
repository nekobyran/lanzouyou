import 'package:lanzou_library_shell/models/source_registry.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/source_registry_core.dart';

import 'cloud_service.dart';
import 'public_library_storage.dart';
import 'rust_public_library_protocol.dart';

/// Batched adapter for the Rust-owned SourceRegistry.
///
/// The adapter accepts access codes only as write-only request fields. Every
/// response is recursively rejected if it contains credential-shaped keys.
class RustSourceRegistryCore implements SourceRegistryFullCore {
  RustSourceRegistryCore.production(
    this._dispatch, {
    PublicLibraryStorageRootProvider? storageRootProvider,
  }) : _storageRoot = PublicLibraryStorageRoot(provider: storageRootProvider);

  RustSourceRegistryCore.testHarness(this._dispatch, String storageRoot)
    : _storageRoot = PublicLibraryStorageRoot.fixed(storageRoot);

  final RustJsonDispatch _dispatch;
  final PublicLibraryStorageRoot _storageRoot;

  @override
  Future<SourceRegistrySnapshot> sourceRegistrySnapshot() async {
    final data = await _request('source_registry_snapshot');
    return _parseRegistry(
      () => SourceRegistrySnapshot.fromJson(data),
      '来源注册表快照无效',
    );
  }

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
    final data = await _request('source_registry_page', {
      'cursor': cursor,
      'limit': limit,
      'query': query,
      'categoryId': categoryId,
      'kind': kind,
      'searchable': ?searchable,
      'childDirectory': ?childDirectory,
      'builtIn': ?builtIn,
    });
    return _parseRegistry(() => SourceRegistryPage.fromJson(data), '来源注册表分页无效');
  }

  @override
  Future<SourceRegistryImportResult> sourceRegistryBatchImport({
    required int expectedGeneration,
    required List<SourceRegistrySourceDraft> sources,
  }) async {
    final data = await _request('source_registry_batch_import', {
      'expectedGeneration': expectedGeneration,
      'sources': sources
          .map((source) => source.toJson())
          .toList(growable: false),
    });
    return _parseRegistry(
      () => SourceRegistryImportResult.fromJson(data),
      '来源批量导入响应无效',
    );
  }

  @override
  Future<SourceRegistryImportPreview> sourceRegistryImportPreview({
    required int expectedGeneration,
    required String rawText,
    String categoryId = '',
  }) async {
    final data = await _request('source_registry_import_preview', {
      'expectedGeneration': expectedGeneration,
      'rawText': rawText,
      'categoryId': categoryId,
    });
    return _parseRegistry(
      () => SourceRegistryImportPreview.fromJson(data),
      '来源导入预览响应无效',
    );
  }

  @override
  Future<SourceRegistryImportResult> sourceRegistryCommitImportPreview({
    required int expectedGeneration,
    required String previewId,
  }) async {
    final data = await _request('source_registry_commit_import_preview', {
      'expectedGeneration': expectedGeneration,
      'previewId': previewId,
    });
    return _parseRegistry(
      () => SourceRegistryImportResult.fromJson(data),
      '来源导入提交响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryRetest({
    required int expectedGeneration,
    required List<String> sourceIds,
  }) async {
    final data = await _request('source_registry_retest', {
      'expectedGeneration': expectedGeneration,
      'sourceIds': sourceIds,
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '来源重测响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryUpdateSource({
    required int expectedGeneration,
    required SourceRegistrySourceUpdateDraft update,
  }) async {
    final data = await _request('source_registry_update_source', {
      'expectedGeneration': expectedGeneration,
      'update': update.toJson(),
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '来源更新响应无效',
    );
  }

  @override
  Future<SourceRegistryDeleteResult> sourceRegistryDeleteSources({
    required int expectedGeneration,
    required List<String> sourceIds,
  }) async {
    final data = await _request('source_registry_delete_sources', {
      'expectedGeneration': expectedGeneration,
      'sourceIds': sourceIds,
    });
    return _parseRegistry(
      () => SourceRegistryDeleteResult.fromJson(data),
      '来源删除响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryUpsertCategory({
    required int expectedGeneration,
    required SourceRegistryCategoryDraft category,
  }) async {
    final data = await _request('source_registry_category_upsert', {
      'expectedGeneration': expectedGeneration,
      'category': category.toJson(),
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '来源分类响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryDeleteCategory({
    required int expectedGeneration,
    required String categoryId,
  }) async {
    final data = await _request('source_registry_category_delete', {
      'expectedGeneration': expectedGeneration,
      'categoryId': categoryId,
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '来源分类删除响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistrySetCategoryMembers({
    required int expectedGeneration,
    required String categoryId,
    required List<String> sourceIds,
  }) async {
    final data = await _request('source_registry_category_set_members', {
      'expectedGeneration': expectedGeneration,
      'categoryId': categoryId,
      'sourceIds': sourceIds,
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '来源分类成员响应无效',
    );
  }

  @override
  Future<SourceRegistryCompositeMutation> sourceRegistryUpsertComposite({
    required int expectedGeneration,
    required SourceRegistryCompositeDraft composite,
  }) async {
    final data = await _request('source_registry_composite_upsert', {
      'expectedGeneration': expectedGeneration,
      'composite': composite.toJson(),
    });
    return _parseRegistry(
      () => SourceRegistryCompositeMutation.fromJson(data),
      '自建合集响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryDeleteComposite({
    required int expectedGeneration,
    required String sourceId,
  }) async {
    final data = await _request('source_registry_composite_delete', {
      'expectedGeneration': expectedGeneration,
      'sourceId': sourceId,
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '自建合集删除响应无效',
    );
  }

  @override
  Future<SourceRegistryExportResult> sourceRegistryExportRules({
    required int expectedGeneration,
    required String destinationPath,
    List<String> sourceIds = const [],
    bool includeCredentials = false,
    String credentialConfirmation = '',
  }) async {
    final data = await _request('source_registry_rules_export', {
      'expectedGeneration': expectedGeneration,
      'destinationPath': destinationPath,
      'sourceIds': sourceIds,
      'includeCredentials': includeCredentials,
      'credentialConfirmation': credentialConfirmation,
    });
    return _parseRegistry(
      () => SourceRegistryExportResult.fromJson(data),
      '来源规则导出响应无效',
    );
  }

  @override
  Future<SourceRegistryImportResult> sourceRegistryImportRules({
    required int expectedGeneration,
    required String sourcePath,
  }) async {
    final data = await _request('source_registry_rules_import', {
      'expectedGeneration': expectedGeneration,
      'sourcePath': sourcePath,
    });
    return _parseRegistry(
      () => SourceRegistryImportResult.fromJson(data),
      '来源规则导入响应无效',
    );
  }

  @override
  Future<SourceRegistryImportResult> sourceRegistryFetchImportRules({
    required int expectedGeneration,
    required String rulesUrl,
  }) async {
    final data = await _request('source_registry_rules_fetch_import', {
      'expectedGeneration': expectedGeneration,
      'rulesUrl': rulesUrl,
    });
    return _parseRegistry(
      () => SourceRegistryImportResult.fromJson(data),
      '来源规则网络导入响应无效',
    );
  }

  @override
  Future<SourceRegistryMutation> sourceRegistryRestoreBackup(
    int expectedGeneration,
  ) => _mutation('source_registry_restore_backup', expectedGeneration);

  @override
  Future<SourceRegistryMutation> sourceRegistryRestoreOfficial(
    int expectedGeneration,
  ) => _mutation('source_registry_restore_official', expectedGeneration);

  @override
  Future<SourceRegistryMutation> sourceRegistryReset(int expectedGeneration) =>
      _mutation('source_registry_reset', expectedGeneration);

  Future<SourceRegistryMutation> _mutation(
    String operation,
    int expectedGeneration,
  ) async {
    final data = await _request(operation, {
      'expectedGeneration': expectedGeneration,
    });
    return _parseRegistry(
      () => SourceRegistryMutation.fromJson(data),
      '来源注册表操作响应无效',
    );
  }

  Future<Map<String, Object?>> _request(
    String operation, [
    Map<String, Object?> fields = const {},
  ]) async {
    try {
      final storageRoot = await _storageRoot.resolve();
      final data = await _dispatch({
        'op': operation,
        'storageRoot': storageRoot,
        ...fields,
      });
      validatePasswordFreePublicLibraryPayload(data);
      return data;
    } on LibraryCoreFailure {
      rethrow;
    } on CloudFailure catch (error) {
      throw LibraryCoreFailure(
        error.code,
        error.message,
        retriable: error.retriable,
      );
    } on FormatException catch (error) {
      throw LibraryCoreFailure('invalidResponse', error.message);
    } on Object {
      throw const LibraryCoreFailure(
        'coreUnavailable',
        '来源注册表核心调用失败，请稍后重试',
        retriable: true,
      );
    }
  }
}

T _parseRegistry<T>(T Function() parser, String message) {
  try {
    return parser();
  } on FormatException catch (error) {
    throw LibraryCoreFailure('invalidResponse', '$message：${error.message}');
  }
}
