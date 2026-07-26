import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/models/download_history.dart';

void main() {
  test(
    'history JSON round-trip preserves retry metadata without a password',
    () {
      final entry = DownloadHistoryEntry(
        id: 'download-1',
        operationId: 'download-1',
        sourceId: 'main',
        shareUrl: 'https://www.lanzouw.com/i000000',
        itemStableKey: 'main|item',
        displayName: '示例软件',
        suggestedFileName: 'example.apk',
        filePath: r'C:\Users\tester\Downloads\example.apk',
        status: DownloadHistoryStatus.succeeded,
        bytesTransferred: 4096,
        totalBytes: 4096,
        createdAt: DateTime.utc(2026, 7, 14, 1),
        updatedAt: DateTime.utc(2026, 7, 14, 1, 1),
        completedAt: DateTime.utc(2026, 7, 14, 1, 1),
      );

      final encoded = jsonEncode(entry.toJson());
      final decoded = DownloadHistoryEntry.fromJson(
        (jsonDecode(encoded) as Map).cast<String, Object?>(),
      );

      expect(decoded.toJson(), entry.toJson());
      expect(encoded.toLowerCase(), isNot(contains('password')));
      expect(encoded, isNot(contains('private-value')));
    },
  );

  test('history rejects impossible byte progress and unsafe operation IDs', () {
    final base = {
      'id': 'download-1',
      'operationId': 'download-1',
      'sourceId': 'main',
      'shareUrl': 'https://www.lanzouw.com/i000000',
      'itemStableKey': 'main|item',
      'displayName': '示例软件',
      'suggestedFileName': 'example.apk',
      'filePath': '',
      'status': 'downloading',
      'bytesTransferred': 5,
      'totalBytes': 4,
      'createdAt': '2026-07-14T01:00:00.000Z',
      'updatedAt': '2026-07-14T01:00:00.000Z',
      'completedAt': null,
      'errorCode': '',
      'errorMessage': '',
    };

    expect(() => DownloadHistoryEntry.fromJson(base), throwsFormatException);
    expect(
      () => DownloadHistoryEntry.fromJson({
        ...base,
        'operationId': 'contains/slash',
        'bytesTransferred': 0,
      }),
      throwsFormatException,
    );
  });

  test('history rejects share URLs containing embedded credentials', () {
    final json = {
      'id': 'download-1',
      'operationId': 'download-1',
      'sourceId': 'main',
      'shareUrl': 'https://user:private-value@www.lanzouw.com/i000000',
      'itemStableKey': 'main|item',
      'displayName': '示例软件',
      'suggestedFileName': 'example.apk',
      'filePath': '',
      'status': 'downloading',
      'bytesTransferred': 0,
      'totalBytes': 0,
      'createdAt': '2026-07-14T01:00:00.000Z',
      'updatedAt': '2026-07-14T01:00:00.000Z',
      'completedAt': null,
      'errorCode': '',
      'errorMessage': '',
    };

    expect(() => DownloadHistoryEntry.fromJson(json), throwsFormatException);
  });

  test('file suffixes map to the LanzouMax semantic download filters', () {
    expect(
      classifyDownloadExtension('release.APK'),
      DownloadExtensionCategory.installationPackage,
    );
    expect(
      classifyDownloadExtension('desktop.MSIX'),
      DownloadExtensionCategory.application,
    );
    expect(
      classifyDownloadExtension('backup.tar.gz'),
      DownloadExtensionCategory.archive,
    );
    expect(
      classifyDownloadExtension('manual.PDF'),
      DownloadExtensionCategory.document,
    );
    expect(
      classifyDownloadExtension('demo.webm'),
      DownloadExtensionCategory.video,
    );
    expect(
      classifyDownloadExtension('theme.flac'),
      DownloadExtensionCategory.audio,
    );
    expect(
      classifyDownloadExtension('README'),
      DownloadExtensionCategory.other,
    );
  });

  test('live snapshots expose speed and ETA only from real progress', () {
    const unknown = DownloadSnapshot(
      operationId: 'unknown',
      historyId: 'unknown',
      itemStableKey: 'main|unknown',
      fileName: 'unknown.apk',
      state: DownloadActivityState.downloading,
      bytesTransferred: 1024,
      totalBytes: 4096,
    );
    const measured = DownloadSnapshot(
      operationId: 'measured',
      historyId: 'measured',
      itemStableKey: 'main|measured',
      fileName: 'measured.apk',
      state: DownloadActivityState.downloading,
      bytesTransferred: 1024,
      totalBytes: 4096,
      bytesPerSecond: 1024,
    );

    expect(unknown.estimatedRemaining, isNull);
    expect(measured.estimatedRemaining, const Duration(seconds: 3));
  });
}
