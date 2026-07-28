import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/repositories/library_remote_content_repository.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;
  late DateTime now;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'lanzou_remote_content_',
    );
    now = DateTime.now();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'uses a SHA-256 named persistent cache before downloading again',
    () async {
      var downloads = 0;
      final repository = _repository(
        temporaryDirectory,
        now: () => now,
        imageLoader: (_) async {
          downloads++;
          return _pngHeader;
        },
      );

      expect(
        await repository.loadImage('https://assets.example.test/banner.png'),
        _pngHeader,
      );
      expect(
        await repository.loadImage('https://assets.example.test/banner.png'),
        _pngHeader,
      );

      expect(downloads, 1);
      final files = temporaryDirectory.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(
        p.basename(files.single.path),
        matches(RegExp(r'^[a-f0-9]{64}\.bin$')),
      );
      expect(files.single.path, isNot(contains('assets.example.test')));
    },
  );

  test(
    'refreshes stale content and falls back to the old cache on failure',
    () async {
      var failDownload = false;
      var downloads = 0;
      final repository = _repository(
        temporaryDirectory,
        now: () => now,
        imageLoader: (_) async {
          downloads++;
          if (failDownload) throw StateError('offline');
          return _pngHeader;
        },
        maxAge: const Duration(minutes: 30),
      );

      await repository.loadImage('https://assets.example.test/stale.png');
      now = now.add(const Duration(hours: 2));
      failDownload = true;

      expect(
        await repository.loadImage('https://assets.example.test/stale.png'),
        _pngHeader,
      );
      expect(downloads, 2);
    },
  );

  test(
    'enforces HTTPS, byte limits and strict UTF-8 without poisoning cache',
    () async {
      final exactBoundary = Uint8List.fromList(
        List<int>.filled(libraryRemoteTextMaxBytes, 0x61),
      );
      final responses = <String, Uint8List>{
        'https://content.example.test/exact.txt': exactBoundary,
        'https://content.example.test/large.txt': Uint8List(
          libraryRemoteTextMaxBytes + 1,
        ),
        'https://content.example.test/invalid.txt': Uint8List.fromList([
          0xC3,
          0x28,
        ]),
        'https://content.example.test/bom.txt': Uint8List.fromList([
          ...utf8.encode('\uFEFF公告正文'),
        ]),
      };
      final repository = _repository(
        temporaryDirectory,
        now: () => now,
        textLoader: (url) async => responses[url]!,
      );

      expect(
        (await repository.loadText(
          'https://content.example.test/exact.txt',
        )).length,
        libraryRemoteTextMaxBytes,
      );
      expect(
        await repository.loadText('https://content.example.test/bom.txt'),
        '公告正文',
      );
      await expectLater(
        repository.loadText('https://content.example.test/large.txt'),
        throwsA(
          isA<LibraryRemoteContentFailure>().having(
            (error) => error.code,
            'code',
            'invalidSize',
          ),
        ),
      );
      await expectLater(
        repository.loadText('https://content.example.test/invalid.txt'),
        throwsA(
          isA<LibraryRemoteContentFailure>().having(
            (error) => error.code,
            'code',
            'invalidUtf8',
          ),
        ),
      );
      await expectLater(
        repository.loadText('http://content.example.test/plain.txt'),
        throwsA(
          isA<LibraryRemoteContentFailure>().having(
            (error) => error.code,
            'code',
            'invalidUrl',
          ),
        ),
      );
      expect(
        temporaryDirectory.listSync().whereType<File>(),
        hasLength(2),
        reason: 'oversized and malformed downloads must never enter the cache',
      );
    },
  );
}

CachedLibraryRemoteContentRepository _repository(
  Directory directory, {
  required DateTime Function() now,
  Future<Uint8List> Function(String)? imageLoader,
  Future<Uint8List> Function(String)? textLoader,
  Duration maxAge = libraryRemoteContentMaxAge,
}) => CachedLibraryRemoteContentRepository.testHarness(
  cacheDirectory: () async => directory,
  imageLoader: imageLoader ?? (_) async => _pngHeader,
  textLoader:
      textLoader ?? (_) async => Uint8List.fromList(utf8.encode('公告正文')),
  clock: now,
  maxAge: maxAge,
);

final Uint8List _pngHeader = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
]);
