import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/services/download_file_opener.dart';
import 'package:lanzou_library_shell/services/download_storage_paths.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'lanzou-shell-platform-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('path provider keeps history under app support data/history', () async {
    final downloads = Directory(p.join(temporaryDirectory.path, 'Downloads'));
    final support = Directory(p.join(temporaryDirectory.path, 'support'));
    final paths = PathProviderDownloadStoragePaths.testHarness(
      getDownloads: () async => downloads,
      getApplicationSupport: () async => support,
    );

    expect(await paths.downloadsDirectory(), downloads.path);
    expect(
      (await paths.historyFile()).path,
      p.join(support.path, 'data', 'history', 'downloads.json'),
    );
    expect(await downloads.exists(), isTrue);
    expect(
      await Directory(p.join(support.path, 'data', 'history')).exists(),
      isTrue,
    );
  });

  test(
    'OpenFilex adapter validates existence and maps plugin failures',
    () async {
      final file = File(p.join(temporaryDirectory.path, 'example.apk'));
      await file.writeAsBytes([1, 2, 3], flush: true);
      final opened = <String>[];
      final opener = OpenFilexDownloadFileOpener.testHarness(
        openFile: (path) async {
          opened.add(path);
          return OpenResult(type: ResultType.done);
        },
      );

      await opener.open(file.path);
      expect(opened, [file.path]);

      final failing = OpenFilexDownloadFileOpener.testHarness(
        openFile: (_) async => OpenResult(type: ResultType.noAppToOpen),
      );
      await expectLater(
        failing.open(file.path),
        throwsA(
          isA<DownloadFileOpenFailure>().having(
            (error) => error.code,
            'code',
            'noApplication',
          ),
        ),
      );
    },
  );

  test(
    'Windows opens the exact metacharacter path through its file association',
    () async {
      final file = File(
        p.join(temporaryDirectory.path, 'tool & echo ^ (safe).apk'),
      );
      await file.writeAsBytes([1, 2, 3], flush: true);
      final associated = <String>[];
      var pluginCalls = 0;
      final opener = OpenFilexDownloadFileOpener.testHarness(
        isWindows: true,
        openFile: (_) async {
          pluginCalls += 1;
          return OpenResult(type: ResultType.done);
        },
        openWindowsAssociation: (path) async {
          associated.add(path);
          return 33;
        },
      );

      await opener.open(file.path);

      expect(pluginCalls, 0);
      expect(associated, [file.path]);
    },
  );

  test(
    'Windows maps missing file association without falling back to a shell',
    () async {
      final file = File(p.join(temporaryDirectory.path, 'unhandled.apk'));
      await file.writeAsBytes([1, 2, 3], flush: true);
      final opener = OpenFilexDownloadFileOpener.testHarness(
        isWindows: true,
        openFile: (_) async => OpenResult(type: ResultType.done),
        openWindowsAssociation: (_) async => 31,
      );

      await expectLater(
        opener.open(file.path),
        throwsA(
          isA<DownloadFileOpenFailure>().having(
            (error) => error.code,
            'code',
            'noApplication',
          ),
        ),
      );
    },
  );
}
