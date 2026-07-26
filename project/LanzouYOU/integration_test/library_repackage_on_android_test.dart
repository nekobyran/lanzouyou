import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lanzouyou/pages/library_builder/library_builder_service.dart';
import 'package:lanzouyou/pages/library_builder/library_recipe.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android host repackages both embedded templates without source builds',
    (tester) async {
      expect(Platform.isAndroid, isTrue);

      final support = await getApplicationSupportDirectory();
      final verificationDirectory = Directory(
        _join(support.path, 'verification', 'library-repackage-on-android'),
      );
      if (await verificationDirectory.exists()) {
        await verificationDirectory.delete(recursive: true);
      }
      await verificationDirectory.parent.create(recursive: true);

      final cache = await getTemporaryDirectory();
      final icon = File(_join(cache.path, 'library-builder-verification.png'));
      await icon.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        flush: true,
      );

      final service = LocalTemplateLibraryBuildService(
        artifactExporter: _VerificationExporter(verificationDirectory),
        cacheDirectoryProvider: () async => cache,
        supportDirectoryProvider: () async => support,
      );
      final recipe = LibraryBuildRecipe(
        schemaVersion: 1,
        identity: const LibraryIdentity(
          projectId: 'verify_library',
          displayName: '验收软件库',
          applicationId: 'cc.nkbr.verifylibrary',
          versionName: '1.2.3',
          versionCode: 123,
          windowsExeName: 'verify-library',
        ),
        branding: const LibraryBranding(
          seedColor: '#2563EB',
          officialUrl: 'https://example.com/',
          publisher: 'LanzouYOU Verification',
        ),
        sources: const [
          LibrarySourceRecipe(
            sourceId: 'verification-source',
            title: '验收源',
            shareUrl: 'https://www.lanzouw.com/',
          ),
        ],
        features: const LibraryFeatures(),
        build: LibraryBuildOptions(
          targets: const {LibraryTarget.android, LibraryTarget.windows},
          iconSourcePath: icon.path,
        ),
      );

      final result = await service.build(recipe);
      expect(result.result, 'pass');
      expect(result.artifacts, hasLength(2));
      final byPlatform = {
        for (final artifact in result.artifacts) artifact.platform: artifact,
      };
      expect(byPlatform.keys, containsAll(<String>['android', 'windows']));
      expect(
        byPlatform['android']!.metadata['packageName'],
        'cc.nkbr.verifylibrary',
      );
      expect(byPlatform['android']!.metadata['versionName'], '1.2.3');
      expect(byPlatform['windows']!.metadata['exeName'], 'verify-library.exe');

      for (final artifact in result.artifacts) {
        final file = File(artifact.path);
        expect(await file.exists(), isTrue);
        final bytes = await file.readAsBytes();
        expect(bytes.length, greaterThan(1024));
        expect(bytes.take(2), orderedEquals(const [0x50, 0x4B]));
        expect(artifact.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(sha256.convert(bytes).toString(), artifact.sha256);
      }
      final manifest = await File(
        _join(verificationDirectory.path, 'manifest.json'),
      ).readAsString();
      expect(manifest, isNot(contains('password')));
      expect(manifest, isNot(contains('sourcePath')));
      expect(manifest, isNot(contains(cache.path)));

      // An external verifier may need a short, opt-in window to pull the
      // generated files before Flutter removes the integration-test package.
      // The ordinary test path stays delay-free.
      if (_verificationHoldSeconds > 0 && _verificationHoldSeconds <= 120) {
        await Future<void>.delayed(Duration(seconds: _verificationHoldSeconds));
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

const _verificationHoldSeconds = int.fromEnvironment(
  'LANZOU_VERIFICATION_HOLD_SECONDS',
);

class _VerificationExporter implements LibraryArtifactExporter {
  const _VerificationExporter(this.directory);

  final Directory directory;

  @override
  Future<LibraryArtifactExportCommit?> exportBatch(
    LibraryArtifactExportBatch batch, {
    LibraryBuildCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (await directory.exists()) {
      throw StateError('Verification output already exists');
    }
    await directory.parent.create(recursive: true);
    final staging = Directory(
      '${directory.path}.staging-${DateTime.now().microsecondsSinceEpoch}',
    );
    final committedPaths = <String, String>{};
    try {
      await staging.create();
      for (final item in batch.items) {
        cancellation?.throwIfCancelled();
        if (!RegExp(r'^[a-z0-9_.+-]+$').hasMatch(item.fileName) ||
            !const {'apk', 'zip'}.contains(item.extension)) {
          throw StateError('Unsafe verification artifact name');
        }
        final output = File(_join(staging.path, item.fileName));
        await File(item.sourcePath).copy(output.path);
        final digest = await sha256.bind(output.openRead()).first;
        if (await output.length() != item.byteLength ||
            digest.toString() != item.sha256) {
          throw StateError('Verification staging digest mismatch');
        }
        cancellation?.throwIfCancelled();
        committedPaths[item.platform] = _join(directory.path, item.fileName);
      }
      final safeManifest = <String, Object?>{
        'schemaVersion': 1,
        'host': 'android',
        'artifacts': [
          for (final item in batch.items)
            <String, Object?>{
              'platform': item.platform,
              'file': item.fileName,
              'bytes': item.byteLength,
              'sha256': item.sha256,
            },
        ],
      };
      await File(_join(staging.path, 'manifest.json')).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(safeManifest)}\n',
        encoding: utf8,
        flush: true,
      );
      cancellation?.beginExternalCommit();
      await staging.rename(directory.path);
      return LibraryArtifactExportCommit(
        path: directory.path,
        fileName: directory.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last,
        isBundle: false,
        artifactPaths: committedPaths,
      );
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }
}

String _join(String first, String second, [String? third]) {
  var value = first;
  for (final part in [second, third]) {
    if (part == null || part.isEmpty) continue;
    value = value.endsWith(Platform.pathSeparator)
        ? '$value$part'
        : '$value${Platform.pathSeparator}$part';
  }
  return value;
}
