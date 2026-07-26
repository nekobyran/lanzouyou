import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/models/download_history.dart';
import 'package:lanzou_library_shell/repositories/download_history_repository.dart';
import 'package:lanzou_library_shell/services/download_coordinator.dart';
import 'package:lanzou_library_shell/services/download_file_opener.dart';
import 'package:lanzou_library_shell/services/download_storage_paths.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;
  late MemoryHistoryRepository repository;
  late FakeDownloadRuntime runtime;
  late RecordingFileOpener fileOpener;
  late DownloadCoordinator coordinator;
  var operationSequence = 0;
  var clockTicks = 0;

  setUp(() async {
    operationSequence = 0;
    clockTicks = 0;
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'lanzou-shell-coordinator-',
    );
    repository = MemoryHistoryRepository();
    runtime = FakeDownloadRuntime();
    fileOpener = RecordingFileOpener();
    coordinator = DownloadCoordinator(
      downloadCore: runtime,
      operationCore: runtime,
      repository: repository,
      paths: FixedDownloadStoragePaths(
        downloadsPath: p.join(temporaryDirectory.path, 'Downloads'),
        applicationSupportPath: p.join(temporaryDirectory.path, 'support'),
      ),
      fileOpener: fileOpener,
      operationIdFactory: () => 'download-${++operationSequence}',
      clock: () => DateTime.utc(2026, 7, 14, 1, 0, ++clockTicks),
      pollInitialDelay: const Duration(milliseconds: 1),
      pollMaxDelay: const Duration(milliseconds: 4),
      controlTimeout: const Duration(seconds: 1),
    );
  });

  tearDown(() async {
    await coordinator.shutdown();
    coordinator.dispose();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'initialization exposes real save directory and repairs interrupted work',
    () async {
      repository.entries = [
        entry(status: DownloadHistoryStatus.downloading),
        entry(id: 'download-queued', status: DownloadHistoryStatus.queued),
      ];

      await coordinator.initialize();

      expect(coordinator.saveDirectory, endsWith('Downloads'));
      expect(coordinator.history, hasLength(2));
      expect(
        coordinator.history.map((item) => item.status),
        everyElement(DownloadHistoryStatus.failed),
      );
      expect(
        coordinator.history.map((item) => item.errorCode),
        everyElement('interrupted'),
      );
      expect(repository.replaceCount, 1);
    },
  );

  test(
    'a completed initialization can retry a transient load failure',
    () async {
      repository.loadFailuresRemaining = 1;

      await coordinator.initialize();
      expect(coordinator.loadError, isNotEmpty);

      await coordinator.initialize();
      expect(coordinator.loadError, isEmpty);
      expect(coordinator.saveDirectory, endsWith('Downloads'));
    },
  );

  test(
    'download waits for first initialization and never loses the new entry',
    () async {
      final loadGate = Completer<void>();
      repository.loadGate = loadGate;
      repository.entries = [entry(status: DownloadHistoryStatus.failed)];

      final initialization = coordinator.initialize();
      await waitUntil(() => repository.loadCount == 1);
      final download = startDownload(coordinator, 'during-initialize');
      await Future<void>.delayed(const Duration(milliseconds: 8));
      expect(coordinator.active, isEmpty);
      expect(runtime.downloads, isEmpty);

      loadGate.complete();
      await initialization;
      final operationId = await download;
      await waitUntil(() => runtime.downloads.isNotEmpty);

      expect(repository.loadCount, 1);
      expect(
        coordinator.history.map((item) => item.id),
        containsAll(<String>['download-interrupted', operationId]),
      );
      runtime.completeNext(
        LibraryDownloadResult(
          path: p.join(coordinator.saveDirectory, 'during-initialize.apk'),
          fileName: 'during-initialize.apk',
          bytesWritten: 1,
        ),
      );
      await waitUntil(() => coordinator.active.isEmpty);
      expect(
        coordinator.history.map((item) => item.id),
        containsAll(<String>['download-interrupted', operationId]),
      );

      await coordinator.initialize();
      expect(repository.loadCount, 1);
    },
  );

  test(
    'interrupted-history repair write failure keeps loaded entries visible',
    () async {
      repository.entries = [entry(status: DownloadHistoryStatus.downloading)];
      repository.replaceFailuresRemaining = 1;

      await coordinator.initialize();

      expect(coordinator.loadError, isEmpty);
      expect(coordinator.persistenceWarning, '无法保存下载记录');
      expect(coordinator.history, hasLength(1));
      expect(coordinator.history.single.status, DownloadHistoryStatus.failed);
      expect(coordinator.history.single.errorCode, 'interrupted');
    },
  );

  test(
    'downloads with real byte progress and persists only safe retry metadata',
    () async {
      await coordinator.initialize();
      final operationId = await coordinator.download(
        sourceId: 'main',
        shareUrl: 'https://www.lanzouw.com/i000000',
        password: 'private-value',
        itemStableKey: 'main|item',
        displayName: '示例软件',
        suggestedFileName: 'example.apk',
      );
      await waitUntil(() => runtime.downloads.length == 1);
      expect(operationId, 'download-1');
      expect(runtime.downloads.single.password, 'private-value');
      expect(
        runtime.downloads.single.destinationDirectory,
        coordinator.saveDirectory,
      );

      runtime.status = operationStatus(
        operationId,
        bytesTransferred: 1024,
        totalBytes: 4096,
      );
      await waitUntil(
        () =>
            coordinator.active.single.state ==
            DownloadActivityState.downloading,
      );
      expect(coordinator.active.single.bytesTransferred, 1024);

      final output = p.join(coordinator.saveDirectory, 'example.apk');
      runtime.completeNext(
        LibraryDownloadResult(
          path: output,
          fileName: 'example.apk',
          bytesWritten: 4096,
        ),
      );
      await waitUntil(() => coordinator.active.isEmpty);

      final completed = coordinator.history.single;
      expect(completed.status, DownloadHistoryStatus.succeeded);
      expect(completed.filePath, output);
      expect(completed.bytesTransferred, 4096);
      expect(completed.totalBytes, 4096);
      expect(completed.toJson().keys, isNot(contains('password')));

      await File(output).writeAsBytes([1]);
      await coordinator.open(completed);
      expect(fileOpener.paths, [output]);
    },
  );

  test('rejects credential-bearing URLs before history persistence', () async {
    await coordinator.initialize();

    await expectLater(
      coordinator.download(
        sourceId: 'main',
        shareUrl: 'https://user:private-value@www.lanzouw.com/i000000',
        password: '',
        itemStableKey: 'main|unsafe-url',
        displayName: '不安全链接',
      ),
      throwsA(
        isA<DownloadCoordinatorFailure>().having(
          (error) => error.code,
          'code',
          'invalidRequest',
        ),
      ),
    );
    expect(coordinator.history, isEmpty);
    expect(repository.entries, isEmpty);
  });

  test('a history write warning never hides real active progress', () async {
    await coordinator.initialize();
    repository.writeFailuresRemaining = 2;
    await startDownload(coordinator, 'write-warning');
    await waitUntil(() => runtime.downloads.isNotEmpty);

    expect(coordinator.loadError, isEmpty);
    expect(coordinator.persistenceWarning, '无法保存下载记录');
    expect(coordinator.active, isNotEmpty);

    runtime.completeNext(
      LibraryDownloadResult(
        path: p.join(coordinator.saveDirectory, 'write-warning.apk'),
        fileName: 'write-warning.apk',
        bytesWritten: 1,
      ),
    );
    await waitUntil(() => coordinator.active.isEmpty);
    expect(coordinator.persistenceWarning, isEmpty);
  });

  test(
    'core errors are persisted only through credential-safe mappings',
    () async {
      await coordinator.initialize();
      final operationId = await coordinator.download(
        sourceId: 'main',
        shareUrl: 'https://www.lanzouw.com/i000000',
        password: 'private-value',
        itemStableKey: 'main|safe-error',
        displayName: '安全错误',
      );
      await waitUntil(() => runtime.downloads.isNotEmpty);

      runtime.completeNextError(
        const LibraryCoreFailure(
          'server_error',
          'private-value https://secret.invalid/direct',
        ),
      );
      await waitUntil(() => coordinator.active.isEmpty);

      final failed = coordinator.history.firstWhere(
        (entry) => entry.id == operationId,
      );
      expect(failed.errorMessage, '下载失败，请稍后重试');
      expect(failed.errorMessage, isNot(contains('private-value')));
      expect(failed.errorMessage, isNot(contains('http')));
    },
  );

  test('open rejects a tampered history path outside real Downloads', () async {
    await coordinator.initialize();
    final outside = p.join(temporaryDirectory.path, 'outside.apk');
    await File(outside).writeAsBytes([1]);
    final tampered = entry(status: DownloadHistoryStatus.failed).copyWith(
      status: DownloadHistoryStatus.succeeded,
      filePath: outside,
      completedAt: DateTime.utc(2026, 7, 14, 1),
    );

    await expectLater(
      coordinator.open(tampered),
      throwsA(
        isA<DownloadCoordinatorFailure>().having(
          (error) => error.code,
          'code',
          'unsafePath',
        ),
      ),
    );
    expect(fileOpener.paths, isEmpty);
  });

  test('open preserves safe actionable file-adapter failures', () async {
    await coordinator.initialize();
    final filePath = p.join(coordinator.saveDirectory, 'missing-handler.apk');
    await File(filePath).writeAsBytes([1]);
    final completed = entry(status: DownloadHistoryStatus.failed).copyWith(
      status: DownloadHistoryStatus.succeeded,
      filePath: filePath,
      completedAt: DateTime.utc(2026, 7, 14, 1),
    );
    fileOpener.error = const DownloadFileOpenFailure(
      'noApplication',
      '没有可打开此文件的应用',
    );

    await expectLater(
      coordinator.open(completed),
      throwsA(
        isA<DownloadCoordinatorFailure>()
            .having((error) => error.code, 'code', 'noApplication')
            .having((error) => error.message, 'message', '没有可打开此文件的应用'),
      ),
    );
  });

  test(
    'open reports a missing completed file without invoking the adapter',
    () async {
      await coordinator.initialize();
      final missingPath = p.join(coordinator.saveDirectory, 'missing.apk');
      final completed = entry(status: DownloadHistoryStatus.failed).copyWith(
        status: DownloadHistoryStatus.succeeded,
        filePath: missingPath,
        completedAt: DateTime.utc(2026, 7, 14, 1),
      );

      await expectLater(
        coordinator.open(completed),
        throwsA(
          isA<DownloadCoordinatorFailure>().having(
            (error) => error.code,
            'code',
            'fileNotFound',
          ),
        ),
      );
      expect(fileOpener.paths, isEmpty);
    },
  );

  test(
    'uses a real FIFO and cancelling a queued item never calls Rust',
    () async {
      await coordinator.initialize();
      final first = await startDownload(coordinator, 'first');
      final second = await startDownload(coordinator, 'second');
      await waitUntil(() => runtime.downloads.length == 1);

      expect(coordinator.active, hasLength(2));
      expect(coordinator.active.last.state, DownloadActivityState.queued);
      await coordinator.cancel(second);

      expect(runtime.cancelled, isEmpty);
      expect(
        coordinator.history.firstWhere((item) => item.id == second).status,
        DownloadHistoryStatus.cancelled,
      );
      runtime.completeNext(
        LibraryDownloadResult(
          path: p.join(coordinator.saveDirectory, 'first.apk'),
          fileName: 'first.apk',
          bytesWritten: 1,
        ),
      );
      await waitUntil(() => coordinator.active.isEmpty);
      expect(runtime.downloads.single.operationId, first);
    },
  );

  test('the same item cannot be queued twice while non-terminal', () async {
    await coordinator.initialize();
    await startDownload(coordinator, 'duplicate');
    await waitUntil(() => runtime.downloads.isNotEmpty);

    await expectLater(
      startDownload(coordinator, 'duplicate'),
      throwsA(
        isA<DownloadCoordinatorFailure>().having(
          (error) => error.code,
          'code',
          'alreadyQueued',
        ),
      ),
    );
    expect(coordinator.active, hasLength(1));

    runtime.completeNextError(const LibraryCoreFailure('cancelled', '操作已取消'));
    await waitUntil(() => coordinator.active.isEmpty);
  });

  test(
    'native running progress cannot roll a requested cancel backwards',
    () async {
      await coordinator.initialize();
      final operationId = await startDownload(coordinator, 'cancel-monotonic');
      await waitUntil(() => runtime.downloads.isNotEmpty);
      runtime.status = operationStatus(
        operationId,
        bytesTransferred: 1,
        totalBytes: 2,
      );
      await waitUntil(
        () =>
            coordinator.active.single.state ==
            DownloadActivityState.downloading,
      );

      await coordinator.cancel(operationId);
      expect(coordinator.active.single.state, DownloadActivityState.cancelling);
      await Future<void>.delayed(const Duration(milliseconds: 12));
      expect(coordinator.active.single.state, DownloadActivityState.cancelling);

      runtime.completeNextError(const LibraryCoreFailure('cancelled', '操作已取消'));
      await waitUntil(() => coordinator.active.isEmpty);
    },
  );

  test('zero-byte native polling keeps the real resolving phase', () async {
    await coordinator.initialize();
    final operationId = await startDownload(coordinator, 'resolve-phase');
    await waitUntil(() => runtime.downloads.isNotEmpty);
    runtime.status = operationStatus(operationId);
    final initialStatusCalls = runtime.statusCalls;

    await waitUntil(() => runtime.statusCalls >= initialStatusCalls + 3);
    expect(coordinator.active.single.state, DownloadActivityState.resolving);
    expect(coordinator.history.single.status, DownloadHistoryStatus.resolving);
    expect(coordinator.active.single.bytesTransferred, 0);
    expect(coordinator.active.single.totalBytes, 0);

    runtime.status = operationStatus(operationId, bytesTransferred: 1);
    await waitUntil(
      () =>
          coordinator.active.single.state == DownloadActivityState.downloading,
    );
    runtime.completeNextError(const LibraryCoreFailure('cancelled', '操作已取消'));
    await waitUntil(() => coordinator.active.isEmpty);
  });

  test('failed cancel control restores the real resolving phase', () async {
    await coordinator.initialize();
    final operationId = await startDownload(coordinator, 'cancel-resolving');
    await waitUntil(() => runtime.downloads.isNotEmpty);
    runtime.status = operationStatus(operationId);
    await waitUntil(() => runtime.statusCalls >= 2);
    runtime.cancelError = const LibraryCoreFailure(
      'control_failed',
      'private native cancellation detail',
    );

    await expectLater(
      coordinator.cancel(operationId),
      throwsA(
        isA<DownloadCoordinatorFailure>().having(
          (error) => error.code,
          'code',
          'cancelFailed',
        ),
      ),
    );

    expect(coordinator.active.single.state, DownloadActivityState.resolving);
    expect(coordinator.history.single.status, DownloadHistoryStatus.resolving);

    runtime.cancelError = null;
    runtime.completeNextError(const LibraryCoreFailure('cancelled', '操作已取消'));
    await waitUntil(() => coordinator.active.isEmpty);
  });

  test(
    'retry uses persisted metadata while password stays transient',
    () async {
      final failed = entry(status: DownloadHistoryStatus.failed);
      repository.entries = [failed];
      await coordinator.initialize();

      final operationId = await coordinator.retry(
        failed,
        password: 'retry-private-value',
      );
      await waitUntil(() => runtime.downloads.isNotEmpty);

      expect(operationId, 'download-1');
      expect(runtime.downloads.single.sourceId, failed.sourceId);
      expect(runtime.downloads.single.shareUrl, failed.shareUrl);
      expect(runtime.downloads.single.password, 'retry-private-value');
      expect(
        coordinator.history
            .firstWhere((item) => item.id == operationId)
            .toJson(),
        isNot(containsPair('password', anything)),
      );
      runtime.completeNextError(const LibraryCoreFailure('cancelled', '操作已取消'));
      await waitUntil(() => coordinator.active.isEmpty);
    },
  );

  test(
    'shutdown cancels native work, waits for completion, and never closes core',
    () async {
      await coordinator.initialize();
      final operationId = await startDownload(coordinator, 'shutdown');
      await waitUntil(() => runtime.downloads.isNotEmpty);
      runtime.onCancel = (id) {
        runtime.completeNextError(
          const LibraryCoreFailure('cancelled', '操作已取消'),
        );
      };

      await coordinator.shutdown();

      expect(runtime.cancelled, contains(operationId));
      expect(runtime.closeCalls, 0);
      expect(coordinator.active, isEmpty);
      expect(
        coordinator.history.firstWhere((item) => item.id == operationId).status,
        DownloadHistoryStatus.cancelled,
      );
    },
  );

  test(
    'shutdown still waits for native cleanup when cancel control fails',
    () async {
      await coordinator.initialize();
      final operationId = await startDownload(
        coordinator,
        'cancel-control-fails',
      );
      await waitUntil(() => runtime.downloads.isNotEmpty);
      runtime.cancelError = const LibraryCoreFailure(
        'coreUnavailable',
        'control worker unavailable',
        retriable: true,
      );
      runtime.onCancel = (_) {
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 10), () {
            runtime.completeNextError(
              const LibraryCoreFailure('cancelled', '操作已取消'),
            );
          }),
        );
      };

      await coordinator.shutdown();

      expect(runtime.cancelled, contains(operationId));
      expect(coordinator.active, isEmpty);
      expect(runtime.closeCalls, 0);
    },
  );

  test(
    'real byte samples derive speed and remaining time without guessing',
    () async {
      await coordinator.initialize();
      final operationId = await startDownload(coordinator, 'measured');
      await waitUntil(() => runtime.downloads.isNotEmpty);

      runtime.status = operationStatus(
        operationId,
        bytesTransferred: 1024,
        totalBytes: 4096,
      );
      await waitUntil(() => coordinator.active.single.bytesTransferred == 1024);
      runtime.status = operationStatus(
        operationId,
        bytesTransferred: 2048,
        totalBytes: 4096,
      );
      await waitUntil(() => coordinator.active.single.bytesTransferred == 2048);

      expect(coordinator.active.single.bytesPerSecond, greaterThan(0));
      expect(coordinator.active.single.estimatedRemaining, isNotNull);

      runtime.completeNextError(const LibraryCoreFailure('cancelled', '操作已取消'));
      await waitUntil(() => coordinator.active.isEmpty);
    },
  );

  test(
    'delete file and history validates the real Downloads boundary',
    () async {
      final downloads = await FixedDownloadStoragePaths(
        downloadsPath: p.join(temporaryDirectory.path, 'Downloads'),
        applicationSupportPath: p.join(temporaryDirectory.path, 'support'),
      ).downloadsDirectory();
      final inside = p.join(downloads, 'completed.apk');
      await File(inside).writeAsBytes([1, 2, 3]);
      final completed = entry(status: DownloadHistoryStatus.failed).copyWith(
        status: DownloadHistoryStatus.succeeded,
        filePath: inside,
        bytesTransferred: 3,
        totalBytes: 3,
        completedAt: DateTime.utc(2026, 7, 14, 0, 1),
      );
      repository.entries = [completed];
      await coordinator.initialize();

      await coordinator.deleteFileAndHistory(completed);

      expect(await File(inside).exists(), isFalse);
      expect(coordinator.history, isEmpty);
      expect(repository.entries, isEmpty);
    },
  );

  test('delete file rejects a history path outside Downloads', () async {
    final outside = p.join(temporaryDirectory.path, 'outside.apk');
    await File(outside).writeAsBytes([1]);
    final tampered = entry(status: DownloadHistoryStatus.failed).copyWith(
      status: DownloadHistoryStatus.succeeded,
      filePath: outside,
      bytesTransferred: 1,
      totalBytes: 1,
      completedAt: DateTime.utc(2026, 7, 14, 0, 1),
    );
    repository.entries = [tampered];
    await coordinator.initialize();

    await expectLater(
      coordinator.deleteFileAndHistory(tampered),
      throwsA(
        isA<DownloadCoordinatorFailure>().having(
          (error) => error.code,
          'code',
          'unsafePath',
        ),
      ),
    );

    expect(await File(outside).exists(), isTrue);
    expect(coordinator.history, hasLength(1));
  });
}

Future<String> startDownload(DownloadCoordinator coordinator, String name) =>
    coordinator.download(
      sourceId: 'main',
      shareUrl: 'https://www.lanzouw.com/i000000-$name',
      password: '',
      itemStableKey: 'main|$name',
      displayName: name,
      suggestedFileName: '$name.apk',
    );

DownloadHistoryEntry entry({
  String id = 'download-interrupted',
  required DownloadHistoryStatus status,
}) {
  final terminal = status.isTerminal;
  return DownloadHistoryEntry(
    id: id,
    operationId: id,
    sourceId: 'main',
    shareUrl: 'https://www.lanzouw.com/i000000',
    itemStableKey: 'main|item',
    displayName: '示例软件',
    suggestedFileName: 'example.apk',
    filePath: '',
    status: status,
    bytesTransferred: 1024,
    totalBytes: 4096,
    createdAt: DateTime.utc(2026, 7, 14),
    updatedAt: DateTime.utc(2026, 7, 14, 0, 1),
    completedAt: terminal ? DateTime.utc(2026, 7, 14, 0, 1) : null,
    errorCode: status == DownloadHistoryStatus.failed ? 'network' : '',
    errorMessage: status == DownloadHistoryStatus.failed ? '下载失败' : '',
  );
}

LibraryOperationStatus operationStatus(
  String operationId, {
  int bytesTransferred = 0,
  int totalBytes = 0,
}) => LibraryOperationStatus(
  operationId: operationId,
  kind: 'download',
  state: LibraryOperationState.running,
  completedUnits: 0,
  totalUnits: 1,
  bytesTransferred: bytesTransferred,
  totalBytes: totalBytes,
  itemsFound: 0,
);

Future<void> waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('condition was not reached');
}

class MemoryHistoryRepository implements DownloadHistoryRepository {
  List<DownloadHistoryEntry> entries = [];
  int replaceCount = 0;
  int loadCount = 0;
  int loadFailuresRemaining = 0;
  int writeFailuresRemaining = 0;
  int replaceFailuresRemaining = 0;
  Completer<void>? loadGate;

  @override
  Future<void> clear() async => entries = [];

  @override
  Future<List<DownloadHistoryEntry>> load() async {
    loadCount++;
    final gate = loadGate;
    if (gate != null) await gate.future;
    if (loadFailuresRemaining > 0) {
      loadFailuresRemaining--;
      throw const DownloadHistoryFailure('historyUnavailable', '无法读取下载记录');
    }
    return List.of(entries);
  }

  @override
  Future<void> remove(String id) async {
    entries.removeWhere((entry) => entry.id == id);
  }

  @override
  Future<void> replaceAll(List<DownloadHistoryEntry> entries) async {
    replaceCount++;
    if (replaceFailuresRemaining > 0) {
      replaceFailuresRemaining--;
      throw const DownloadHistoryFailure('historyUnavailable', '无法保存下载记录');
    }
    this.entries = List.of(entries);
  }

  @override
  Future<void> upsert(DownloadHistoryEntry entry) async {
    if (writeFailuresRemaining > 0) {
      writeFailuresRemaining--;
      throw const DownloadHistoryFailure('historyUnavailable', '无法保存下载记录');
    }
    entries.removeWhere((existing) => existing.id == entry.id);
    entries.insert(0, entry);
  }
}

class DownloadInvocation {
  const DownloadInvocation({
    required this.sourceId,
    required this.shareUrl,
    required this.password,
    required this.destinationDirectory,
    required this.operationId,
  });

  final String sourceId;
  final String shareUrl;
  final String password;
  final String destinationDirectory;
  final String operationId;
}

class FakeDownloadRuntime
    implements LibraryDownloadRuntime, LibraryCoreLifecycle {
  final List<DownloadInvocation> downloads = [];
  final List<String> cancelled = [];
  final List<String> forgotten = [];
  final List<Completer<LibraryDownloadResult>> _completions = [];
  LibraryOperationStatus? status;
  void Function(String operationId)? onCancel;
  Object? cancelError;
  int closeCalls = 0;
  int statusCalls = 0;

  @override
  Future<void> cancelOperation(String operationId) async {
    cancelled.add(operationId);
    onCancel?.call(operationId);
    final error = cancelError;
    if (error != null) throw error;
  }

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<LibraryDownloadResult> download({
    required String sourceId,
    required String shareUrl,
    String password = '',
    required String destinationDirectory,
    String? operationId,
  }) {
    final resolvedId = operationId!;
    downloads.add(
      DownloadInvocation(
        sourceId: sourceId,
        shareUrl: shareUrl,
        password: password,
        destinationDirectory: destinationDirectory,
        operationId: resolvedId,
      ),
    );
    final completer = Completer<LibraryDownloadResult>();
    _completions.add(completer);
    return completer.future;
  }

  void completeNext(LibraryDownloadResult result) {
    _completions
        .firstWhere((completer) => !completer.isCompleted)
        .complete(result);
  }

  void completeNextError(Object error) {
    _completions
        .firstWhere((completer) => !completer.isCompleted)
        .completeError(error);
  }

  @override
  Future<void> forgetOperation(String operationId) async {
    forgotten.add(operationId);
  }

  @override
  Future<LibraryOperationStatus> operationStatus(String operationId) async {
    statusCalls++;
    final current = status;
    if (current == null || current.operationId != operationId) {
      throw const LibraryCoreFailure(
        'operation_not_found',
        'operation not registered',
        retriable: true,
      );
    }
    return current;
  }
}

class RecordingFileOpener implements DownloadFileOpener {
  final List<String> paths = [];
  Object? error;

  @override
  Future<void> open(String filePath) async {
    final currentError = error;
    if (currentError != null) throw currentError;
    paths.add(filePath);
  }
}
