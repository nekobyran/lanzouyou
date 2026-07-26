import '../models/source_registry.dart';

/// Password-free, batched contract for the Rust-owned source registry.
///
/// All parsing, normalization, deduplication, generation checks and durable
/// commits stay in Rust. Flutter only sends user-entered fields and renders the
/// bounded DTOs returned by the core.
abstract interface class SourceRegistryCore {
  Future<SourceRegistrySnapshot> sourceRegistrySnapshot();

  Future<SourceRegistryPage> sourceRegistryPage({
    String cursor = '',
    int limit = 100,
    String query = '',
    String categoryId = 'all',
    String kind = 'all',
    bool? searchable,
    bool? childDirectory,
    bool? builtIn,
  });
}

abstract interface class SourceRegistryAddCore {
  Future<SourceRegistryImportResult> sourceRegistryBatchImport({
    required int expectedGeneration,
    required List<SourceRegistrySourceDraft> sources,
  });
}

abstract interface class SourceRegistryRetestCore {
  Future<SourceRegistryMutation> sourceRegistryRetest({
    required int expectedGeneration,
    required List<String> sourceIds,
  });
}

abstract interface class SourceRegistrySourceMutationCore {
  Future<SourceRegistryMutation> sourceRegistryUpdateSource({
    required int expectedGeneration,
    required SourceRegistrySourceUpdateDraft update,
  });

  Future<SourceRegistryDeleteResult> sourceRegistryDeleteSources({
    required int expectedGeneration,
    required List<String> sourceIds,
  });
}

abstract interface class SourceRegistryCategoryCore {
  Future<SourceRegistryMutation> sourceRegistryUpsertCategory({
    required int expectedGeneration,
    required SourceRegistryCategoryDraft category,
  });

  Future<SourceRegistryMutation> sourceRegistryDeleteCategory({
    required int expectedGeneration,
    required String categoryId,
  });

  Future<SourceRegistryMutation> sourceRegistrySetCategoryMembers({
    required int expectedGeneration,
    required String categoryId,
    required List<String> sourceIds,
  });
}

abstract interface class SourceRegistryCompositeCore {
  Future<SourceRegistryCompositeMutation> sourceRegistryUpsertComposite({
    required int expectedGeneration,
    required SourceRegistryCompositeDraft composite,
  });

  Future<SourceRegistryMutation> sourceRegistryDeleteComposite({
    required int expectedGeneration,
    required String sourceId,
  });
}

/// Strict v2 rules import/export capabilities.
abstract interface class SourceRegistryRulesCore {
  Future<SourceRegistryImportResult> sourceRegistryImportRules({
    required int expectedGeneration,
    required String sourcePath,
  });

  Future<SourceRegistryImportResult> sourceRegistryFetchImportRules({
    required int expectedGeneration,
    required String rulesUrl,
  });

  Future<SourceRegistryExportResult> sourceRegistryExportRules({
    required int expectedGeneration,
    required String destinationPath,
    List<String> sourceIds = const [],
    bool includeCredentials = false,
    String credentialConfirmation = '',
  });
}

abstract interface class SourceRegistryRestoreCore {
  Future<SourceRegistryMutation> sourceRegistryRestoreBackup(
    int expectedGeneration,
  );

  Future<SourceRegistryMutation> sourceRegistryRestoreOfficial(
    int expectedGeneration,
  );

  Future<SourceRegistryMutation> sourceRegistryReset(int expectedGeneration);
}

/// Exposed only when Rust supports a two-phase plain-text import transaction.
/// The preview is password-free; access codes stay behind its opaque ID.
abstract interface class SourceRegistryImportPreviewCore {
  Future<SourceRegistryImportPreview> sourceRegistryImportPreview({
    required int expectedGeneration,
    required String rawText,
    String categoryId = '',
  });

  Future<SourceRegistryImportResult> sourceRegistryCommitImportPreview({
    required int expectedGeneration,
    required String previewId,
  });
}

/// Convenience nominal interface used by the production Rust adapter.
///
/// UI checks the smaller interfaces individually, so read-only or partially
/// capable hosts never display actions that they cannot execute.
abstract interface class SourceRegistryFullCore
    implements
        SourceRegistryCore,
        SourceRegistryAddCore,
        SourceRegistryRetestCore,
        SourceRegistrySourceMutationCore,
        SourceRegistryCategoryCore,
        SourceRegistryCompositeCore,
        SourceRegistryImportPreviewCore,
        SourceRegistryRulesCore,
        SourceRegistryRestoreCore {}

typedef SourceRegistryPathPicker = Future<String?> Function();
