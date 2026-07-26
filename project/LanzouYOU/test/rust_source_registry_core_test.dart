import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/models/source_registry.dart';
import 'package:lanzou_library_shell/services/library_core.dart';
import 'package:lanzou_library_shell/services/source_registry_core.dart';
import 'package:lanzouyou/services/rust_source_registry_core.dart';

void main() {
  test(
    'SourceRegistry snapshot stays password-free and uses one Rust call',
    () async {
      final requests = <Map<String, Object?>>[];
      final core = RustSourceRegistryCore.testHarness((request) async {
        requests.add(request);
        return <String, Object?>{
          'generation': 4,
          'baselineRevision': 'catalog-v1',
          'baselineCount': 606,
          'userCount': 1,
          'mergedCount': 607,
          'categories': <Object?>[],
          'userSources': <Object?>[
            <String, Object?>{
              'id': 'https://www.lanzouw.com/b1',
              'kind': 'official',
              'title': 'Tools',
              'publisher': '',
              'description': '',
              'avatarUrl': '',
              'shareUrl': 'https://www.lanzouw.com/b1',
              'searchable': true,
              'childDirectory': false,
              'originPath': '',
              'originUrl': '',
              'memberCount': 0,
              'builtIn': false,
            },
          ],
        };
      }, r'D:\app-data');

      final snapshot = await core.sourceRegistrySnapshot();

      expect(snapshot.generation, 4);
      expect(snapshot.baselineCount, 606);
      expect(snapshot.userSources.single.title, 'Tools');
      expect(requests, hasLength(1));
      expect(requests.single, {
        'op': 'source_registry_snapshot',
        'storageRoot': r'D:\app-data',
      });
    },
  );

  test(
    'batch import sends access codes only as write-only request data',
    () async {
      late Map<String, Object?> captured;
      final core = RustSourceRegistryCore.testHarness((request) async {
        captured = request;
        return <String, Object?>{
          'generation': 1,
          'added': 1,
          'duplicates': 0,
          'invalid': 0,
        };
      }, r'D:\app-data');

      final result = await core.sourceRegistryBatchImport(
        expectedGeneration: 0,
        sources: const [
          SourceRegistrySourceDraft(
            title: 'Tools',
            url: 'https://www.lanzouw.com/b1',
            accessCode: 'write-only-code',
            searchable: true,
          ),
        ],
      );

      expect(result.generation, 1);
      expect(result.added, 1);
      final sources = captured['sources']! as List<Object?>;
      expect(
        (sources.single as Map<String, Object?>)['password'],
        'write-only-code',
      );
    },
  );

  test('SourceRegistry rejects credential-shaped response fields', () async {
    final core = RustSourceRegistryCore.testHarness(
      (_) async => <String, Object?>{
        'generation': 0,
        'baselineRevision': 'catalog-v1',
        'baselineCount': 606,
        'userCount': 0,
        'mergedCount': 606,
        'categories': <Object?>[],
        'userSources': <Object?>[],
        'password': 'must-not-cross-ffi',
      },
      r'D:\app-data',
    );

    await expectLater(
      core.sourceRegistrySnapshot(),
      throwsA(
        isA<LibraryCoreFailure>().having(
          (error) => error.code,
          'code',
          'unsafeResponse',
        ),
      ),
    );
  });

  test('SourceRegistry requires an absolute storage root before dispatch', () {
    expect(
      () => RustSourceRegistryCore.testHarness(
        (_) async => const {},
        'relative/data',
      ),
      throwsArgumentError,
    );
  });

  test('two-phase text import never returns access codes to Flutter', () async {
    final requests = <Map<String, Object?>>[];
    final core = RustSourceRegistryCore.testHarness((request) async {
      requests.add(request);
      if (request['op'] == 'source_registry_import_preview') {
        return <String, Object?>{
          'generation': 2,
          'previewId': 'opaque-preview-1',
          'valid': <Object?>[
            <String, Object?>{
              'line': 1,
              'title': '工具库',
              'shareUrl': 'https://www.lanzouw.com/b1',
              'requiresCode': true,
              'categoryId': '',
            },
          ],
          'duplicates': <Object?>[],
          'invalid': <Object?>[],
        };
      }
      return <String, Object?>{
        'generation': 3,
        'added': 1,
        'duplicates': 0,
        'invalid': 0,
      };
    }, r'D:\app-data');

    final preview = await core.sourceRegistryImportPreview(
      expectedGeneration: 2,
      rawText: 'https://www.lanzouw.com/b1 write-only-code',
    );
    expect(preview.valid.single.requiresCode, isTrue);
    expect(preview.previewId, 'opaque-preview-1');
    final result = await core.sourceRegistryCommitImportPreview(
      expectedGeneration: 2,
      previewId: preview.previewId,
    );
    expect(result.added, 1);
    expect(requests.map((request) => request['op']), <Object?>[
      'source_registry_import_preview',
      'source_registry_commit_import_preview',
    ]);
  });

  test(
    'production adapter exposes every nominal SourceRegistry capability',
    () {
      final core = RustSourceRegistryCore.testHarness(
        (_) async => const <String, Object?>{},
        r'D:\app-data',
      );
      expect(core, isA<SourceRegistryFullCore>());
      expect(core, isA<SourceRegistrySourceMutationCore>());
      expect(core, isA<SourceRegistryRulesCore>());
    },
  );

  test(
    'filters and mutation/rules fields stay in single batched calls',
    () async {
      final requests = <Map<String, Object?>>[];
      final core = RustSourceRegistryCore.testHarness((request) async {
        requests.add(request);
        return switch (request['op']) {
          'source_registry_page' => <String, Object?>{
            'generation': 1,
            'total': 0,
            'nextCursor': '',
            'hasMore': false,
            'sources': <Object?>[],
          },
          'source_registry_delete_sources' => <String, Object?>{
            'generation': 2,
            'removed': 1,
            'hidden': 0,
            'missing': 0,
          },
          'source_registry_rules_export' => <String, Object?>{
            'generation': 2,
            'count': 1,
            'bytesWritten': 128,
            'sha256': List<String>.filled(64, 'A').join(),
          },
          _ => <String, Object?>{'generation': 2},
        };
      }, r'D:\app-data');

      await core.sourceRegistryPage(
        kind: 'official',
        searchable: true,
        childDirectory: false,
        builtIn: false,
      );
      await core.sourceRegistryUpdateSource(
        expectedGeneration: 1,
        update: const SourceRegistrySourceUpdateDraft(
          sourceId: 'https://www.lanzouw.com/b1',
          title: 'Renamed',
          searchable: true,
          accessCode: 'write-only',
        ),
      );
      await core.sourceRegistryDeleteSources(
        expectedGeneration: 1,
        sourceIds: const ['https://www.lanzouw.com/b1'],
      );
      await core.sourceRegistryExportRules(
        expectedGeneration: 2,
        destinationPath: r'D:\rules.json',
        includeCredentials: true,
        credentialConfirmation: 'export-source-access-codes',
      );

      expect(requests[0], containsPair('kind', 'official'));
      expect(requests[0], containsPair('searchable', true));
      expect(requests[0], containsPair('childDirectory', false));
      expect(requests[0], containsPair('builtIn', false));
      expect(
        (requests[1]['update']! as Map<String, Object?>)['accessCode'],
        'write-only',
      );
      expect(requests[2]['op'], 'source_registry_delete_sources');
      expect(requests[3]['includeCredentials'], true);
      expect(
        requests[3]['credentialConfirmation'],
        'export-source-access-codes',
      );
    },
  );
}
