import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/library_builder/library_builder_page.dart';
import 'package:lanzouyou/pages/library_builder/library_builder_service.dart';
import 'package:lanzouyou/pages/library_builder/library_recipe.dart';

void main() {
  const share = ShareInfo(
    id: 'folder-id',
    isFolder: true,
    name: '我的软件库',
    shareUrl: 'https://example.lanzouw.com/b123',
    password: 'a1b2',
    description: '示例简介',
  );

  test('share info creates a v1 multi-source recipe without account data', () {
    final recipe = LibraryBuildRecipe.fromShareInfo(share);

    expect(recipe.schemaVersion, 1);
    expect(recipe.sources, hasLength(1));
    expect(recipe.sources.single.shareUrl, share.shareUrl);
    expect(recipe.sources.single.password, share.password);
    expect(recipe.hasEmbeddedPasswords, isTrue);
    expect(recipe.toJson().toString(), isNot(contains('cookie')));
    expect(recipe.toJson().toString(), isNot(contains('account')));
    expect(recipe.validate(), isEmpty);
  });

  test(
    'new project has a valid editable identity and no fabricated source',
    () {
      final recipe = LibraryBuildRecipe.newProject();

      expect(recipe.schemaVersion, 1);
      expect(recipe.identity.displayName, '我的软件库');
      expect(recipe.sources, isEmpty);
      expect(recipe.toJson().toString(), isNot(contains('shareUrl: https://')));
      expect(recipe.validate(), ['软件库来源必须为 1-4096 个']);
    },
  );

  test('recipe JSON round trip preserves targets and source ids', () {
    final original = LibraryBuildRecipe.fromShareInfo(share).copyWith(
      build: const LibraryBuildOptions(
        targets: {LibraryTarget.android, LibraryTarget.windows},
        iconSourcePath: r'C:\icons\library.png',
      ),
    );

    final decoded = LibraryBuildRecipe.fromJson(original.toJson());

    expect(decoded, original);
    expect(decoded.runtimeJson()['build'], isNull);
    expect(decoded.runtimeJson()['sources'], isA<List<Object?>>());
    expect(
      (decoded.runtimeJson()['branding'] as Map)['logoAsset'],
      'assets/runtime/logo.png',
    );
    expect((decoded.runtimeJson()['branding'] as Map)['themeMode'], 'system');
  });

  test('v1 parser rejects missing fields and preserves access-code bytes', () {
    final json = LibraryBuildRecipe.fromShareInfo(share).toJson();
    final sources = json['sources']! as List<Object?>;
    (sources.single as Map<String, Object?>)['password'] = ' a1b2 ';
    expect(LibraryBuildRecipe.fromJson(json).sources.single.password, ' a1b2 ');

    final branding = json['branding']! as Map<String, Object?>;
    branding.remove('themeMode');
    expect(() => LibraryBuildRecipe.fromJson(json), throwsFormatException);
  });

  test('redacted project JSON removes passwords and local icon paths', () {
    final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
      build: const LibraryBuildOptions(
        iconSourcePath: r'C:\private\library-icon.png',
      ),
    );

    final redacted = recipe.redactedJson().toString();

    expect(redacted, isNot(contains('password')));
    expect(redacted, isNot(contains(share.password)));
    expect(redacted, isNot(contains('library-icon.png')));
  });

  test('automatic project save persists no access-code field', () async {
    final root = await Directory.systemTemp.createTemp('library-store-test-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = LocalLibraryProjectStore(
      supportDirectoryProvider: () async => root,
    );
    final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
      build: const LibraryBuildOptions(iconSourcePath: r'C:\secret\icon.png'),
    );

    final path = await store.save(recipe);
    final persisted = await File(path).readAsString();

    expect(persisted, isNot(contains('password')));
    expect(persisted, isNot(contains(share.password)));
    expect(persisted, isNot(contains('secret')));
  });

  test('validation rejects unsafe identity and duplicate source ids', () {
    final source = LibrarySourceRecipe.fromShareInfo(share);
    final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
      identity: const LibraryIdentity(
        projectId: '../escape',
        displayName: '',
        applicationId: 'bad id',
        versionName: 'v next',
        versionCode: 0,
        windowsExeName: '../escape',
      ),
      sources: [source, source],
    );

    expect(recipe.validate(), isNotEmpty);
  });

  test(
    'validation supports 606 catalog roots and keeps a bounded overlay cap',
    () {
      final base = LibraryBuildRecipe.fromShareInfo(share);
      List<LibrarySourceRecipe> sources(int count) => List.generate(
        count,
        (index) => base.sources.single.copyWith(
          sourceId: 'source-$index',
          title: '软件库 $index',
        ),
        growable: false,
      );

      expect(base.copyWith(sources: sources(606)).validate(), isEmpty);
      expect(base.copyWith(sources: sources(4096)).validate(), isEmpty);
      expect(base.copyWith(sources: sources(4097)).validate(), isNotEmpty);
    },
  );

  test('suggested project ids always satisfy the canonical slug length', () {
    expect(suggestProjectId('a'), 'a_library');
    expect(
      RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(suggestProjectId('a')),
      isTrue,
    );
    expect(suggestProjectId('我的软件库'), 'custom_library');
    expect(suggestProjectId('con'), 'con_library');
  });

  test('validation mirrors package identity limits', () {
    final base = LibraryBuildRecipe.fromShareInfo(share);
    final invalid = base.copyWith(
      identity: base.identity.copyWith(
        projectId: 'con',
        applicationId: 'cc.${List.filled(125, 'a').join()}',
        versionName: '65536.1',
        versionCode: 0x100000000,
        windowsExeName: 'nul',
      ),
    );

    expect(invalid.validate(), hasLength(greaterThanOrEqualTo(5)));
  });

  test('source validation uses the audited Lanzou share-domain allowlist', () {
    final base = LibraryBuildRecipe.fromShareInfo(share);
    for (final url in const [
      'https://lanzouw.com/b123',
      'https://www.lanzouw.com/b123',
      'https://pan.lanzoui.com/b123?next=:443',
    ]) {
      expect(
        base
            .copyWith(sources: [base.sources.single.copyWith(shareUrl: url)])
            .validate(),
        isEmpty,
      );
    }
    for (final url in const [
      'https://www.lanzouw.com:443/b123',
      'https://www.lanzouw.com:444/b123',
      'https://lanzou0.com/b123',
      'https://lanzou1.com/b123',
      'https://lanzoua.com/b123',
      'https://evil-lanzouw.com/b123',
      'https://lanzouw.com.evil.test/b123',
      'https://www.lanzouw.com./b123',
    ]) {
      expect(
        base
            .copyWith(sources: [base.sources.single.copyWith(shareUrl: url)])
            .validate(),
        isNotEmpty,
      );
    }
  });

  test(
    'asset template loader verifies and caches one complete generation',
    () async {
      final assets = _validTemplateAssets();
      final bundle = _MemoryAssetBundle(assets);
      final loader = AssetLibraryTemplateLoader(bundle: bundle);

      expect(await loader.load(LibraryTarget.android), [1, 2, 3]);
      expect(await loader.load(LibraryTarget.windows), [4, 5, 6]);

      assets[AssetLibraryTemplateLoader.androidAsset] = Uint8List.fromList([9]);
      expect(await loader.load(LibraryTarget.android), [1, 2, 3]);
      expect(bundle.loadCounts[AssetLibraryTemplateLoader.manifestAsset], 1);
      expect(bundle.loadCounts[AssetLibraryTemplateLoader.androidAsset], 1);
      expect(bundle.loadCounts[AssetLibraryTemplateLoader.windowsAsset], 1);
    },
  );

  test(
    'asset template loader rejects a tampered artifact binding safely',
    () async {
      final manifest = _validTemplateManifest();
      final artifacts = manifest['artifacts']! as List<Object?>;
      (artifacts.first as Map<String, Object?>)['file'] = '../other.apk';

      await _expectSafeTemplateFailure(_assetsWithManifest(manifest));
    },
  );

  test(
    'asset template loader rejects a missing manifest field safely',
    () async {
      final manifest = _validTemplateManifest()..remove('purpose');

      await _expectSafeTemplateFailure(_assetsWithManifest(manifest));
    },
  );

  test('asset template loader rejects an old manifest schema safely', () async {
    final manifest = _validTemplateManifest()..['schemaVersion'] = 1;

    await _expectSafeTemplateFailure(_assetsWithManifest(manifest));
  });

  test(
        'asset template loader rejects an artifact byte-length mismatch safely',
    () async {
      final assets = _validTemplateAssets();
            assets[AssetLibraryTemplateLoader.windowsAsset] = Uint8List.fromList([
        4,
        5,
      ]);

      await _expectSafeTemplateFailure(assets);
    },
  );

  testWidgets('new-project entry adds a real source before packaging', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeBuildService(canBuild: true);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBuilderPage.newProject(
          buildService: service,
          projectStore: _FakeProjectStore(),
          hostPlatform: TargetPlatform.android,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('软件库'), findsOneWidget);
    expect(find.byKey(const Key('library-builder-narrow')), findsOneWidget);
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('library-builder-narrow')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('library-empty-sources')),
      300,
      scrollable: scrollable,
    );
    expect(find.text('尚未添加来源'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('library-empty-sources')),
        matching: find.widgetWithText(OutlinedButton, '添加'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('library-add-source-title')),
      '正式来源',
    );
    await tester.enterText(
      find.byKey(const Key('library-add-source-url')),
      'https://www.lanzouw.com/b123',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('source-motion-source-1')),
      findsOneWidget,
    );
    expect(find.text('正式来源'), findsOneWidget);
    expect(service.calls, 0);
  });

  testWidgets('narrow Android builder packages locally without a toolchain', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeBuildService(canBuild: true);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: LibraryBuilderPage(
          shareInfo: Future.value(share),
          buildService: service,
          projectStore: _FakeProjectStore(),
          hostPlatform: TargetPlatform.android,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-builder-narrow')), findsOneWidget);
    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.descendant(
              of: find.byKey(const Key('library-builder-body-motion')),
              matching: find.byType(AnimatedSwitcher),
            ),
          )
          .duration,
      Duration.zero,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('我的软件库'), findsWidgets);
    expect(find.textContaining('成品中分发'), findsOneWidget);
    final editorScrollable = find
        .descendant(
          of: find.byKey(const Key('library-builder-narrow')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('library-source-password-0')),
      300,
      scrollable: editorScrollable,
    );
    final passwordField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('library-source-password-0')),
        matching: find.byType(TextField),
      ),
    );
    expect(passwordField.obscureText, isTrue);
    tester
        .widget<IconButton>(
          find.byKey(const Key('library-source-password-visibility')),
        )
        .onPressed!();
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('library-source-password-0')),
              matching: find.byType(TextField),
            ),
          )
          .obscureText,
      isFalse,
    );
    final scrollableState = tester.state<ScrollableState>(editorScrollable);
    scrollableState.position.jumpTo(scrollableState.position.maxScrollExtent);
    await tester.pump();
    tester
        .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '搜索'))
        .onChanged!(false);
    await tester.pump();
    expect(find.text('Android 64位安装包（APK）'), findsOneWidget);
    expect(find.text('Windows x64 便携版（ZIP）'), findsOneWidget);
    expect(find.textContaining('清除 LanzouYOU 数据'), findsOneWidget);
    await tester.tap(find.byKey(const Key('library-build-button')));
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(service.lastRecipe?.features.search, isFalse);
    expect(find.byKey(const Key('library-artifact-results')), findsOneWidget);
    expect(find.byKey(const Key('library-artifact-bundle')), findsOneWidget);
    expect(find.text('包内产物'), findsOneWidget);
    expect(find.textContaining('已生成'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide builder exposes preview and invokes Windows build', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeBuildService(canBuild: true);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBuilderPage(
          shareInfo: Future.value(share.copyWithPassword('')),
          buildService: service,
          projectStore: _FakeProjectStore(),
          hostPlatform: TargetPlatform.windows,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-builder-wide')), findsOneWidget);
    expect(find.text('生成摘要'), findsOneWidget);
    await tester.tap(find.byKey(const Key('library-build-button')));
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(find.byKey(const Key('library-artifact-results')), findsOneWidget);
    expect(find.byKey(const Key('library-artifact-bundle')), findsOneWidget);
    expect(find.textContaining('已生成'), findsWidgets);
  });

  testWidgets('busy builder exposes an accessible active cancellation state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeBuildService(
      canBuild: true,
      waitForCancellation: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBuilderPage(
          shareInfo: Future.value(share),
          buildService: service,
          projectStore: _FakeProjectStore(),
          hostPlatform: TargetPlatform.android,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('library-builder-narrow')),
          matching: find.byType(Scrollable),
        )
        .first;
    tester
        .state<ScrollableState>(scrollable)
        .position
        .jumpTo(
          tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        );
    await tester.pump();

    await tester.tap(find.byKey(const Key('library-build-button')));
    await tester.pump();
    expect(find.text('取消生成'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const Key('library-build-cancel-button')),
    );
    expect(semantics.label, contains('取消生成'));

    await tester.tap(find.byKey(const Key('library-build-cancel-button')));
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.byKey(const Key('library-build-cancel-button')), findsNothing);
    expect(find.textContaining('操作失败'), findsNothing);
  });

  testWidgets('file picker cancellation is reported as cancelled, not failed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBuilderPage(
          shareInfo: Future.value(share),
          buildService: _FakeBuildService(
            canBuild: true,
            cancelDuringExport: true,
          ),
          projectStore: _FakeProjectStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library-build-button')));
    await tester.pumpAndSettle();

    expect(find.text('已取消'), findsOneWidget);
    expect(find.textContaining('操作失败'), findsNothing);
  });

  testWidgets('add-source dialog hides access code by default', (tester) async {
    await tester.binding.setSurfaceSize(const Size(760, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryBuilderPage(
          shareInfo: Future.value(share),
          buildService: _FakeBuildService(canBuild: true),
          projectStore: _FakeProjectStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editorScrollable = find
        .descendant(
          of: find.byKey(const Key('library-builder-narrow')),
          matching: find.byType(Scrollable),
        )
        .first;
    final scrollableState = tester.state<ScrollableState>(editorScrollable);
    scrollableState.position.jumpTo(
      scrollableState.position.maxScrollExtent * 0.55,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '添加'));
    await tester.pumpAndSettle();

    final password = tester.widget<TextField>(
      find.byKey(const Key('library-add-source-password')),
    );
    expect(password.obscureText, isTrue);
  });

  test(
    'Android host repackages APK and Windows ZIP then removes job files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-builder-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final cache = Directory('${root.path}${Platform.pathSeparator}cache');
      final support = Directory('${root.path}${Platform.pathSeparator}support');
      final dispatcher = _FakeCoreDispatcher();
      final exporter = _FakeArtifactExporter();
      final service = LocalTemplateLibraryBuildService(
        dispatcher: dispatcher,
        templateLoader: const _FakeTemplateLoader(),
        artifactExporter: exporter,
        cacheDirectoryProvider: () async => cache,
        supportDirectoryProvider: () async => support,
        isSupportedHost: true,
      );
      final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
        build: const LibraryBuildOptions(
          targets: {LibraryTarget.android, LibraryTarget.windows},
        ),
      );

      final result = await service.build(recipe);

      expect(result.result, 'pass');
      expect(result.export?.isBundle, isTrue);
      expect(result.artifacts.map((item) => item.platform), [
        'android',
        'windows',
      ]);
      expect(dispatcher.requests.map((item) => item['op']), [
        'library_repackage_android',
        'library_repackage_windows',
      ]);
      expect(dispatcher.requests.first, contains('signingIdentityPath'));
      expect(dispatcher.requests.last, isNot(contains('signingIdentityPath')));
      expect(
        dispatcher.requests.first['runtimeConfig'],
        isNot(contains('build')),
      );
      expect(exporter.calls, 1);
      expect(exporter.fileNames, [
        'custom_library-1.0.0.apk',
        'custom_library-1.0.0.zip',
      ]);
      final jobs = Directory(
        '${cache.path}${Platform.pathSeparator}lanzouyou'
        '${Platform.pathSeparator}library-builder',
      );
      expect(await jobs.exists(), isTrue);
      expect(await jobs.list().isEmpty, isTrue);
      final signingPath =
          dispatcher.requests.first['signingIdentityPath']! as String;
      expect(
        signingPath,
        contains(
          '${Platform.pathSeparator}data${Platform.pathSeparator}signing',
        ),
      );
      expect(
        File(signingPath).absolute.path.toLowerCase(),
        isNot(
          startsWith(
            '${cache.absolute.path}${Platform.pathSeparator}'.toLowerCase(),
          ),
        ),
      );
    },
  );

  test(
    'second target failure leaves exporter untouched and removes the job',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-builder-failure-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final cache = Directory('${root.path}${Platform.pathSeparator}cache');
      final exporter = _FakeArtifactExporter();
      final service = LocalTemplateLibraryBuildService(
        dispatcher: _FakeCoreDispatcher(failOnRequest: 2),
        templateLoader: const _FakeTemplateLoader(),
        artifactExporter: exporter,
        cacheDirectoryProvider: () async => cache,
        supportDirectoryProvider: () async =>
            Directory('${root.path}${Platform.pathSeparator}support'),
        isSupportedHost: true,
      );
      final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
        build: const LibraryBuildOptions(
          targets: {LibraryTarget.android, LibraryTarget.windows},
        ),
      );

      await expectLater(service.build(recipe), throwsStateError);

      expect(exporter.calls, 0);
      final jobs = Directory(
        '${cache.path}${Platform.pathSeparator}lanzouyou'
        '${Platform.pathSeparator}library-builder',
      );
      expect(await jobs.list().isEmpty, isTrue);
    },
  );

  test(
    'active cancellation waits for the current target then skips export and cleans the job',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-builder-cancel-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final cache = Directory('${root.path}${Platform.pathSeparator}cache');
      final currentTargetStarted = Completer<void>();
      final finishCurrentTarget = Completer<void>();
      final dispatcher = _FakeCoreDispatcher(
        firstRequestStarted: currentTargetStarted,
        finishFirstRequest: finishCurrentTarget,
      );
      final exporter = _FakeArtifactExporter();
      final service = LocalTemplateLibraryBuildService(
        dispatcher: dispatcher,
        templateLoader: const _FakeTemplateLoader(),
        artifactExporter: exporter,
        cacheDirectoryProvider: () async => cache,
        supportDirectoryProvider: () async =>
            Directory('${root.path}${Platform.pathSeparator}support'),
        isSupportedHost: true,
      );
      final cancellation = LibraryBuildCancellation();
      final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
        build: const LibraryBuildOptions(
          targets: {LibraryTarget.android, LibraryTarget.windows},
        ),
      );

      final build = service.build(recipe, cancellation: cancellation);
      await currentTargetStarted.future;
      cancellation.cancel();
      finishCurrentTarget.complete();

      await expectLater(build, throwsA(isA<LibraryBuildCancelled>()));
      expect(dispatcher.requests, hasLength(1));
      expect(exporter.calls, 0);
      final jobs = Directory(
        '${cache.path}${Platform.pathSeparator}lanzouyou'
        '${Platform.pathSeparator}library-builder',
      );
      expect(await jobs.list().isEmpty, isTrue);
    },
  );

  test(
    'save dialog cancellation cleans the job and reports cancellation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-builder-picker-cancel-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final cache = Directory('${root.path}${Platform.pathSeparator}cache');
      final exporter = _FakeArtifactExporter(cancel: true);
      final service = LocalTemplateLibraryBuildService(
        dispatcher: _FakeCoreDispatcher(),
        templateLoader: const _FakeTemplateLoader(),
        artifactExporter: exporter,
        cacheDirectoryProvider: () async => cache,
        supportDirectoryProvider: () async =>
            Directory('${root.path}${Platform.pathSeparator}support'),
        isSupportedHost: true,
      );

      await expectLater(
        service.build(LibraryBuildRecipe.fromShareInfo(share)),
        throwsA(isA<LibraryBuildCancelled>()),
      );

      expect(exporter.calls, 1);
      final jobs = Directory(
        '${cache.path}${Platform.pathSeparator}lanzouyou'
        '${Platform.pathSeparator}library-builder',
      );
      expect(await jobs.list().isEmpty, isTrue);
    },
  );

  test(
    'cancellation during export preparation never starts the external commit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library-builder-export-cancel-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final cache = Directory('${root.path}${Platform.pathSeparator}cache');
      final exporter = _WaitingArtifactExporter();
      final cancellation = LibraryBuildCancellation();
      final service = LocalTemplateLibraryBuildService(
        dispatcher: _FakeCoreDispatcher(),
        templateLoader: const _FakeTemplateLoader(),
        artifactExporter: exporter,
        cacheDirectoryProvider: () async => cache,
        supportDirectoryProvider: () async =>
            Directory('${root.path}${Platform.pathSeparator}support'),
        isSupportedHost: true,
      );

      final build = service.build(
        LibraryBuildRecipe.fromShareInfo(share),
        cancellation: cancellation,
      );
      await exporter.preparationStarted.future;
      expect(cancellation.cancel(), isTrue);
      exporter.finishPreparation.complete();

      await expectLater(build, throwsA(isA<LibraryBuildCancelled>()));
      expect(exporter.externalCommitStarted, isFalse);
      expect(exporter.externalWrites, 0);
      final jobs = Directory(
        '${cache.path}${Platform.pathSeparator}lanzouyou'
        '${Platform.pathSeparator}library-builder',
      );
      expect(await jobs.list().isEmpty, isTrue);
    },
  );

  test('external commit fence rejects late cancellation', () async {
    final root = await Directory.systemTemp.createTemp(
      'library-builder-commit-fence-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final source = File('${root.path}${Platform.pathSeparator}artifact.apk');
    await source.writeAsBytes(const [1, 2, 3], flush: true);
    final cancellation = LibraryBuildCancellation();
    var saveCalls = 0;
    final exporter = FilePickerLibraryArtifactExporter(
      saveFile:
          ({
            required Uint8List bytes,
            required String fileName,
            required String extension,
          }) async {
            saveCalls++;
            expect(cancellation.canCancel, isFalse);
            expect(cancellation.cancel(), isFalse);
            return 'memory://$fileName';
          },
    );
    

    final result = await exporter.exportBatch(
      LibraryArtifactExportBatch(
        projectId: 'custom_library',
        versionName: '1.0.0',
        items: [
          LibraryArtifactExportItem(
            platform: 'android',
            sourcePath: source.path,
            fileName: 'custom_library-1.0.0.apk',
            extension: 'apk',
                        byteLength: 3,
            metadata: const {},
          ),
        ],
      ),
      cancellation: cancellation,
    );

    expect(saveCalls, 1);
    expect(result?.fileName, 'custom_library-1.0.0.apk');
  });

  test('local artifact export atomically replaces the selected file', () async {
    final root = await Directory.systemTemp.createTemp(
      'library-builder-atomic-save-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final source = File('${root.path}${Platform.pathSeparator}artifact.apk');
    final target = File('${root.path}${Platform.pathSeparator}selected.apk');
    await source.writeAsBytes(const [4, 5, 6], flush: true);
    await target.writeAsBytes(const [9], flush: true);
    final exporter = FilePickerLibraryArtifactExporter(
      pickSavePath:
          ({required String fileName, required String extension}) async =>
              target.path,
    );

    final result = await exporter.exportBatch(
      LibraryArtifactExportBatch(
        projectId: 'custom_library',
        versionName: '1.0.0',
        items: [
          LibraryArtifactExportItem(
            platform: 'android',
            sourcePath: source.path,
            fileName: 'custom_library-1.0.0.apk',
            extension: 'apk',
                        byteLength: 3,
            metadata: const {},
          ),
        ],
      ),
    );

    expect(result?.path, target.path);
    expect(await target.readAsBytes(), const [4, 5, 6]);
    final temporaryFiles = await root
        .list()
        .where(
          (entry) =>
              entry is File &&
              entry.path.contains('.lanzouyou-') &&
              entry.path.endsWith('.tmp'),
        )
        .toList();
    expect(temporaryFiles, isEmpty);
  });

    test('core byte-count mismatch leaves exporter untouched', () async {
    final root = await Directory.systemTemp.createTemp(
            'library-builder-byte-count-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final exporter = _FakeArtifactExporter();
    final service = LocalTemplateLibraryBuildService(
            dispatcher: _FakeCoreDispatcher(corruptByteLength: true),
      templateLoader: const _FakeTemplateLoader(),
      artifactExporter: exporter,
      cacheDirectoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}cache'),
      supportDirectoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}support'),
      isSupportedHost: true,
    );

    await expectLater(
      service.build(LibraryBuildRecipe.fromShareInfo(share)),
      throwsStateError,
    );

    expect(exporter.calls, 0);
  });

  test('real dual-target exporter commits one safe atomic bundle', () async {
    final root = await Directory.systemTemp.createTemp(
      'library-builder-bundle-test-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    var saveCalls = 0;
    Uint8List? savedBytes;
    String? savedFileName;
    String? savedExtension;
    final exporter = FilePickerLibraryArtifactExporter(
      saveFile:
          ({
            required Uint8List bytes,
            required String fileName,
            required String extension,
          }) async {
            saveCalls++;
            savedBytes = Uint8List.fromList(bytes);
            savedFileName = fileName;
            savedExtension = extension;
            return 'memory://$fileName';
          },
    );
    final service = LocalTemplateLibraryBuildService(
      dispatcher: _FakeCoreDispatcher(),
      templateLoader: const _FakeTemplateLoader(),
      artifactExporter: exporter,
      cacheDirectoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}cache'),
      supportDirectoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}support'),
      isSupportedHost: true,
    );
    final recipe = LibraryBuildRecipe.fromShareInfo(share).copyWith(
      build: const LibraryBuildOptions(
        targets: {LibraryTarget.android, LibraryTarget.windows},
      ),
    );

    final result = await service.build(recipe);

    expect(saveCalls, 1);
    expect(savedFileName, 'custom_library-1.0.0-android-windows.zip');
    expect(savedExtension, 'zip');
    expect(result.export?.isBundle, isTrue);
    expect(result.artifacts.map((item) => item.bundleEntry), [
      'custom_library-1.0.0.apk',
      'custom_library-1.0.0.zip',
    ]);

    final bundle = ZipDecoder().decodeBytes(savedBytes!);
    expect(bundle.files.map((entry) => entry.name).toSet(), {
      'custom_library-1.0.0.apk',
      'custom_library-1.0.0.zip',
      'manifest.json',
    });
    expect(bundle.files, hasLength(3));
    final manifestText = utf8.decode(
      bundle.findFile('manifest.json')!.readBytes()!,
    );
    expect(manifestText, isNot(contains('password')));
    expect(manifestText, isNot(contains(share.password)));
    expect(manifestText, isNot(contains(root.path)));
    expect(manifestText, isNot(contains('sourcePath')));
    final manifest = jsonDecode(manifestText) as Map<String, Object?>;
    final artifacts = manifest['artifacts']! as List<Object?>;
    expect(artifacts, hasLength(2));
    for (final artifact in artifacts.cast<Map<String, Object?>>()) {
      final fileName = artifact['fileName']! as String;
      final bytes = bundle.findFile(fileName)!.readBytes()!;
      expect(artifact['bytes'], bytes.length);
                  expect(artifact.keys, containsAll(<String>['platform', 'fileName', 'bytes', 'identity']));

    }
  });
}

extension on ShareInfo {
  ShareInfo copyWithPassword(String value) => ShareInfo(
    id: id,
    isFolder: isFolder,
    name: name,
    shareUrl: shareUrl,
    password: value,
    description: description,
    directUrl: directUrl,
  );
}

class _FakeBuildService implements LibraryBuildService {
  _FakeBuildService({
    required this.canBuild,
    this.waitForCancellation = false,
    this.cancelDuringExport = false,
  });

  @override
  final bool canBuild;

  int calls = 0;
  LibraryBuildRecipe? lastRecipe;
  final bool waitForCancellation;
  final bool cancelDuringExport;

  @override
  String get unavailableReason => '当前设备仅支持保存和导出';

  @override
  Future<LibraryBuildResult> build(
    LibraryBuildRecipe recipe, {
    LibraryBuildCancellation? cancellation,
  }) async {
    calls++;
    lastRecipe = recipe;
    if (waitForCancellation) {
      while (cancellation?.isCancelled != true) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      throw const LibraryBuildCancelled();
    }
    if (cancelDuringExport) throw const LibraryBuildCancelled();
    return const LibraryBuildResult(
      result: 'pass',
      artifacts: [
        LibraryBuildArtifact(
          platform: 'android',
          path: 'bundle://sample/android.apk',
          fileName: 'sample.apk',
                    bundleEntry: 'sample.apk',
          byteLength: 3,
        ),
        LibraryBuildArtifact(
          platform: 'windows',
          path: 'bundle://sample/windows.zip',
          fileName: 'sample.zip',
                    bundleEntry: 'sample.zip',
          byteLength: 3,
        ),
      ],
      export: LibraryBuildExport(
        path: 'memory://sample.zip',
        fileName: 'sample.zip',
        isBundle: true,
      ),
    );
  }
}

class _FakeProjectStore implements LibraryProjectStore {
  @override
  Future<String?> export(LibraryBuildRecipe recipe) async => 'recipe.json';

  @override
  Future<String> save(LibraryBuildRecipe recipe) async => 'recipe.json';
}

class _FakeCoreDispatcher implements LibraryCoreDispatcher {
  _FakeCoreDispatcher({
    this.failOnRequest,
        this.corruptByteLength = false,
    this.firstRequestStarted,
    this.finishFirstRequest,
  });

  final int? failOnRequest;
    final bool corruptByteLength;
  final Completer<void>? firstRequestStarted;
  final Completer<void>? finishFirstRequest;
  final requests = <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> dispatch(Map<String, Object?> request) async {
    requests.add(Map.unmodifiable(request));
    if (requests.length == 1 && firstRequestStarted != null) {
      firstRequestStarted!.complete();
      await finishFirstRequest?.future;
    }
    if (requests.length == failOnRequest) {
      throw StateError('simulated core failure');
    }
    final output = File(request['outputPath']! as String);
    final bytes = request['op'] == 'library_repackage_android'
        ? const [1, 2, 3]
        : const [4, 5, 6];
    await output.writeAsBytes(bytes, flush: true);
        final reportedBytes = corruptByteLength ? bytes.length + 1 : bytes.length;
    if (request['op'] == 'library_repackage_android') {
      return {
        'apkPath': output.path,
        'bytes': reportedBytes,
        'signingVerified': true,
        'packageName': 'cc.nkbr.customlibrary',
        'versionName': '1.0.0',
        'versionCode': 1,
      };
    }
    return {
      'archivePath': output.path,
      'bytes': reportedBytes,
      'exeName': 'custom-library.exe',
    };
  }
}

class _FakeTemplateLoader implements LibraryTemplateLoader {
  const _FakeTemplateLoader();

  @override
  Future<Uint8List> load(LibraryTarget target) async =>
      Uint8List.fromList(target == LibraryTarget.android ? [0x41] : [0x57]);
}

class _FakeArtifactExporter implements LibraryArtifactExporter {
  _FakeArtifactExporter({this.cancel = false});

  final bool cancel;
  int calls = 0;
  final fileNames = <String>[];

  @override
  Future<LibraryArtifactExportCommit?> exportBatch(
    LibraryArtifactExportBatch batch, {
    LibraryBuildCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    calls++;
    fileNames.addAll(batch.items.map((item) => item.fileName));
    if (cancel) return null;
    cancellation?.beginExternalCommit();
    final bundle = batch.items.length > 1;
    final fileName = bundle
        ? '${batch.projectId}-${batch.versionName}-android-windows.zip'
        : batch.items.single.fileName;
    return LibraryArtifactExportCommit(
      path: 'memory://$fileName',
      fileName: fileName,
      isBundle: bundle,
      artifactPaths: bundle
          ? const {}
          : {batch.items.single.platform: 'memory://$fileName'},
    );
  }
}

class _WaitingArtifactExporter implements LibraryArtifactExporter {
  final preparationStarted = Completer<void>();
  final finishPreparation = Completer<void>();
  var externalCommitStarted = false;
  var externalWrites = 0;

  @override
  Future<LibraryArtifactExportCommit?> exportBatch(
    LibraryArtifactExportBatch batch, {
    LibraryBuildCancellation? cancellation,
  }) async {
    preparationStarted.complete();
    await finishPreparation.future;
    cancellation?.throwIfCancelled();
    cancellation?.beginExternalCommit();
    externalCommitStarted = true;
    externalWrites++;
    final item = batch.items.single;
    return LibraryArtifactExportCommit(
      path: 'memory://${item.fileName}',
      fileName: item.fileName,
      isBundle: false,
      artifactPaths: {item.platform: 'memory://${item.fileName}'},
    );
  }
}

Map<String, Uint8List> _validTemplateAssets() =>
    _assetsWithManifest(_validTemplateManifest());

Map<String, Uint8List> _assetsWithManifest(Map<String, Object?> manifest) => {
  AssetLibraryTemplateLoader.manifestAsset: Uint8List.fromList(
    utf8.encode(jsonEncode(manifest)),
  ),
  AssetLibraryTemplateLoader.androidAsset: Uint8List.fromList([1, 2, 3]),
  AssetLibraryTemplateLoader.windowsAsset: Uint8List.fromList([4, 5, 6]),
};

Map<String, Object?> _validTemplateManifest() => {
  'schemaVersion': 2,
  'purpose': 'maintainer-precompiled-shell-templates',
  'generation': {
    'runId': '0123456789abcdef0123456789abcdef',
    'generatedAt': '2026-07-14T00:00:00.000Z',
  },
  'coreAbi': {
    'version': 1,
    'exports': ['lanzouyou_dispatch', 'lanzouyou_free'],
  },
  'recipeSchemaVersion': 1,
  'targets': ['android', 'windows'],
  'artifacts': [
    {
      'target': 'android',
      'file': 'lanzou_library_shell_android.apk',
            'bytes': 3,
    },
    {
      'target': 'windows',
      'file': 'lanzou_library_shell_windows.zip',
            'bytes': 3,
    },
  ],
};

Future<void> _expectSafeTemplateFailure(Map<String, Uint8List> assets) async {
  final loader = AssetLibraryTemplateLoader(bundle: _MemoryAssetBundle(assets));
  try {
    await loader.load(LibraryTarget.android);
    fail('Expected template validation to fail.');
  } on FormatException catch (error) {
    expect(error.message, '内置软件库模板校验失败');
    expect('$error', isNot(contains('runId')));
    expect('$error', isNot(contains('0123456789abcdef')));
    expect('$error', isNot(contains('../other.apk')));
  }
}

class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(this.assets);

  final Map<String, Uint8List> assets;
  final loadCounts = <String, int>{};

  @override
  Future<ByteData> load(String key) async {
    loadCounts.update(key, (value) => value + 1, ifAbsent: () => 1);
    final bytes = assets[key];
    if (bytes == null) throw FlutterError('missing test asset');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}
