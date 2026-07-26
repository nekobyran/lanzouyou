import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/models/download_history.dart';
import 'package:lanzou_library_shell/repositories/download_history_repository.dart';
import 'package:lanzou_library_shell/services/download_storage_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;
  late DownloadStoragePaths paths;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'lanzou-shell-history-',
    );
    paths = FixedDownloadStoragePaths(
      downloadsPath: p.join(temporaryDirectory.path, 'Downloads'),
      applicationSupportPath: p.join(temporaryDirectory.path, 'support'),
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('persists status updates with one current schema', () async {
    final repository = JsonDownloadHistoryRepository(paths: paths);
    final running = historyEntry(status: DownloadHistoryStatus.downloading);
    await repository.upsert(running);
    await repository.upsert(
      running.copyWith(
        status: DownloadHistoryStatus.succeeded,
        filePath: p.join(temporaryDirectory.path, 'Downloads', 'example.apk'),
        bytesTransferred: 8192,
        totalBytes: 8192,
        updatedAt: DateTime.utc(2026, 7, 14, 1, 2),
        completedAt: DateTime.utc(2026, 7, 14, 1, 2),
      ),
    );

    final reloaded = JsonDownloadHistoryRepository(paths: paths);
    final entries = await reloaded.load();
    expect(entries, hasLength(1));
    expect(entries.single.status, DownloadHistoryStatus.succeeded);
    expect(entries.single.bytesTransferred, 8192);
    expect(entries.single.filePath, endsWith('example.apk'));

    final historyFile = await paths.historyFile();
    expect(await historyFile.exists(), isTrue);
    expect(await File('${historyFile.path}.bak').exists(), isFalse);
    expect(
      historyFile.parent.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.tmp'),
      ),
      isEmpty,
    );
  });

  test('quarantines corrupt JSON instead of silently overwriting it', () async {
    final historyFile = await paths.historyFile();
    await historyFile.parent.create(recursive: true);
    await historyFile.writeAsString('{not-json', flush: true);
    final repository = JsonDownloadHistoryRepository(
      paths: paths,
      clock: () => DateTime.utc(2026, 7, 14, 2),
    );

    await expectLater(
      repository.load(),
      throwsA(
        isA<DownloadHistoryFailure>().having(
          (error) => error.code,
          'code',
          'historyCorrupt',
        ),
      ),
    );
    expect(await historyFile.exists(), isFalse);
    expect(
      historyFile.parent.listSync().whereType<File>().where(
        (file) => p.basename(file.path).startsWith('downloads.corrupt-'),
      ),
      hasLength(1),
    );
    expect(await repository.load(), isEmpty);
  });

  test('recovers an interrupted atomic replace from the backup', () async {
    final historyFile = await paths.historyFile();
    await historyFile.parent.create(recursive: true);
    final backup = File('${historyFile.path}.bak');
    await backup.writeAsString('{"schemaVersion":1,"entries":[]}', flush: true);

    final repository = JsonDownloadHistoryRepository(paths: paths);
    expect(await repository.load(), isEmpty);
    expect(await historyFile.exists(), isTrue);
    expect(await backup.exists(), isFalse);
  });
}

DownloadHistoryEntry historyEntry({required DownloadHistoryStatus status}) =>
    DownloadHistoryEntry(
      id: 'download-1',
      operationId: 'download-1',
      sourceId: 'main',
      shareUrl: 'https://www.lanzouw.com/i000000',
      itemStableKey: 'main|item',
      displayName: '示例软件',
      suggestedFileName: 'example.apk',
      filePath: '',
      status: status,
      bytesTransferred: 1024,
      totalBytes: 8192,
      createdAt: DateTime.utc(2026, 7, 14, 1),
      updatedAt: DateTime.utc(2026, 7, 14, 1, 1),
    );
