import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/rust_cloud_service.dart';
import 'library_recipe.dart';

class LibraryBuildArtifact {
  const LibraryBuildArtifact({
    required this.platform,
    required this.path,
    required this.byteLength,
    this.fileName = '',
    this.bundleEntry,
    this.metadata = const {},
  });

  final String platform;
  final String path;
  final int byteLength;
  final String fileName;
  final String? bundleEntry;
  final Map<String, Object?> metadata;
}

class LibraryBuildExport {
  const LibraryBuildExport({
    required this.path,
    required this.fileName,
    required this.isBundle,
  });

  final String path;
  final String fileName;
  final bool isBundle;
}

class LibraryBuildResult {
  const LibraryBuildResult({
    required this.result,
    required this.artifacts,
    this.export,
  });

  final String result;
  final List<LibraryBuildArtifact> artifacts;
  final LibraryBuildExport? export;
}

abstract interface class LibraryBuildService {
  bool get canBuild;

  String get unavailableReason;

  Future<LibraryBuildResult> build(
    LibraryBuildRecipe recipe, {
    LibraryBuildCancellation? cancellation,
  });
}

class LibraryBuildCancellation {
  bool _isCancelled = false;
  bool _externalCommitStarted = false;

  bool get isCancelled => _isCancelled;

  bool get canCancel => !_isCancelled && !_externalCommitStarted;

  bool cancel() {
    if (!canCancel) return false;
    _isCancelled = true;
    return true;
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const LibraryBuildCancelled();
  }

  void beginExternalCommit() {
    throwIfCancelled();
    _externalCommitStarted = true;
  }
}

class LibraryBuildCancelled implements Exception {
  const LibraryBuildCancelled();
}

abstract interface class LibraryCoreDispatcher {
  Future<Map<String, Object?>> dispatch(Map<String, Object?> request);
}

class RustLibraryCoreDispatcher implements LibraryCoreDispatcher {
  RustLibraryCoreDispatcher([RustCloudService? service])
    : _service = service ?? RustCloudService();

  final RustCloudService _service;

  @override
  Future<Map<String, Object?>> dispatch(Map<String, Object?> request) =>
      _service.dispatchRaw(request);
}

abstract interface class LibraryTemplateLoader {
  Future<Uint8List> load(LibraryTarget target);
}

class AssetLibraryTemplateLoader implements LibraryTemplateLoader {
  AssetLibraryTemplateLoader({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  static const manifestAsset = 'assets/templates/templates-manifest.json';
  static const androidAsset =
      'assets/templates/lanzou_library_shell_android.apk';
  static const windowsAsset =
      'assets/templates/lanzou_library_shell_windows.zip';
  static const _safeValidationMessage = '内置软件库模板校验失败';
  static const _expectedPurpose = 'maintainer-precompiled-shell-templates';
  static const _expectedExports = ['lanzouyou_dispatch', 'lanzouyou_free'];
  static const _expectedTargets = ['android', 'windows'];

  final AssetBundle _bundle;
  _VerifiedTemplateGeneration? _verifiedGeneration;
  Future<_VerifiedTemplateGeneration>? _validationInFlight;

  @override
  Future<Uint8List> load(LibraryTarget target) async {
    final generation = await _loadVerifiedGeneration();
    return Uint8List.fromList(generation.templates[target]!);
  }

  Future<_VerifiedTemplateGeneration> _loadVerifiedGeneration() async {
    final cached = _verifiedGeneration;
    if (cached != null) return cached;
    final inFlight = _validationInFlight;
    if (inFlight != null) return inFlight;
    final validation = _validateGeneration();
    _validationInFlight = validation;
    try {
      final verified = await validation;
      _verifiedGeneration = verified;
      return verified;
    } finally {
      _validationInFlight = null;
    }
  }

  Future<_VerifiedTemplateGeneration> _validateGeneration() async {
    try {
      final manifestBytes = await _loadBytes(manifestAsset);
      if (manifestBytes.isEmpty || manifestBytes.length > 64 * 1024) {
        throw const FormatException();
      }
      final decoded = jsonDecode(utf8.decode(manifestBytes));
      final manifest = _exactMap(decoded, const {
        'schemaVersion',
        'purpose',
        'generation',
        'coreAbi',
        'recipeSchemaVersion',
        'targets',
        'artifacts',
      });
      if (manifest['schemaVersion'] != 2 ||
          manifest['purpose'] != _expectedPurpose ||
          manifest['recipeSchemaVersion'] != 1) {
        throw const FormatException();
      }

      final generation = _exactMap(manifest['generation'], const {
        'runId',
        'generatedAt',
      });
      final runId = generation['runId'];
      final generatedAt = generation['generatedAt'];
      if (runId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(runId) ||
          generatedAt is! String ||
          DateTime.tryParse(generatedAt) == null) {
        throw const FormatException();
      }

      final coreAbi = _exactMap(manifest['coreAbi'], const {
        'version',
        'exports',
      });
      if (coreAbi['version'] != 1 ||
          !_exactStringList(coreAbi['exports'], _expectedExports)) {
        throw const FormatException();
      }
      if (!_exactStringList(manifest['targets'], _expectedTargets)) {
        throw const FormatException();
      }

      final artifacts = manifest['artifacts'];
      if (artifacts is! List<Object?> || artifacts.length != 2) {
        throw const FormatException();
      }
      final templates = <LibraryTarget, Uint8List>{};
      for (var index = 0; index < _expectedTargets.length; index++) {
        final targetName = _expectedTargets[index];
        final target = index == 0
            ? LibraryTarget.android
            : LibraryTarget.windows;
        final expectedFile = index == 0
            ? androidAsset.split('/').last
            : windowsAsset.split('/').last;
                final artifact = _exactMap(artifacts[index], const {
          'target',
          'file',
          'bytes',
        });
        final byteLength = artifact['bytes'];
        if (artifact['target'] != targetName ||
            artifact['file'] != expectedFile ||
            byteLength is! int ||
            byteLength <= 0) {
          throw const FormatException();
        }
        final bytes = await _loadBytes('assets/templates/$expectedFile');
        if (bytes.length != byteLength) {
          throw const FormatException();
        }
        templates[target] = Uint8List.fromList(bytes);
      }
      return _VerifiedTemplateGeneration(runId: runId, templates: templates);
    } on Object {
      throw const FormatException(_safeValidationMessage);
    }
  }

  Future<Uint8List> _loadBytes(String asset) async {
    final data = await _bundle.load(asset);
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static Map<String, Object?> _exactMap(
    Object? value,
    Set<String> expectedKeys,
  ) {
    if (value is! Map<String, Object?> ||
        value.length != expectedKeys.length ||
        !value.keys.toSet().containsAll(expectedKeys)) {
      throw const FormatException();
    }
    return value;
  }

  static bool _exactStringList(Object? value, List<String> expected) {
    if (value is! List<Object?> || value.length != expected.length) {
      return false;
    }
    for (var index = 0; index < expected.length; index++) {
      if (value[index] != expected[index]) return false;
    }
    return true;
  }
}

class _VerifiedTemplateGeneration {
  const _VerifiedTemplateGeneration({
    required this.runId,
    required this.templates,
  });

  final String runId;
  final Map<LibraryTarget, Uint8List> templates;
}

class LibraryArtifactExportItem {
  const LibraryArtifactExportItem({
    required this.platform,
    required this.sourcePath,
    required this.fileName,
    required this.extension,
    required this.byteLength,
    required this.metadata,
  });

  final String platform;
  final String sourcePath;
  final String fileName;
  final String extension;
  final int byteLength;
  final Map<String, Object?> metadata;

  Map<String, Object?> safeManifestJson() {
        const safeIdentityKeys = {
      'signingVerified',
      'packageName',
      'versionName',
      'versionCode',
      'exeName',
    };
    return <String, Object?>{
      'platform': platform,
      'fileName': fileName,
            'bytes': byteLength,
      'identity': <String, Object?>{
        for (final entry in metadata.entries)
          if (safeIdentityKeys.contains(entry.key)) entry.key: entry.value,
      },
    };
  }
}

class LibraryArtifactExportBatch {
  const LibraryArtifactExportBatch({
    required this.projectId,
    required this.versionName,
    required this.items,
  });

  final String projectId;
  final String versionName;
  final List<LibraryArtifactExportItem> items;

  Map<String, Object?> safeManifestJson() => <String, Object?>{
    'schemaVersion': 1,
    'format': 'lanzouyou-library-artifact-bundle',
    'artifacts': items.map((item) => item.safeManifestJson()).toList(),
  };
}

class LibraryArtifactExportCommit {
  const LibraryArtifactExportCommit({
    required this.path,
    required this.fileName,
    required this.isBundle,
    this.artifactPaths = const {},
  });

  final String path;
  final String fileName;
  final bool isBundle;
  final Map<String, String> artifactPaths;
}

abstract interface class LibraryArtifactExporter {
  Future<LibraryArtifactExportCommit?> exportBatch(
    LibraryArtifactExportBatch batch, {
    LibraryBuildCancellation? cancellation,
  });
}

typedef LibrarySaveFile =
    Future<String?> Function({
      required Uint8List bytes,
      required String fileName,
      required String extension,
    });

typedef LibraryPickSavePath =
    Future<String?> Function({
      required String fileName,
      required String extension,
    });

class FilePickerLibraryArtifactExporter implements LibraryArtifactExporter {
  const FilePickerLibraryArtifactExporter({this.saveFile, this.pickSavePath});

  final LibrarySaveFile? saveFile;
  final LibraryPickSavePath? pickSavePath;

  @override
  Future<LibraryArtifactExportCommit?> exportBatch(
    LibraryArtifactExportBatch batch, {
    LibraryBuildCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (batch.items.isEmpty || batch.items.length > 2) {
      throw StateError('导出批次目标数量无效');
    }
    if (batch.items.length == 1) {
      final item = batch.items.single;
      final bytes = await _readVerifiedItem(item, cancellation: cancellation);
      cancellation?.beginExternalCommit();
      final path = await _save(
        bytes: bytes,
        fileName: item.fileName,
        extension: item.extension,
      );
      if (path == null) return null;
      return LibraryArtifactExportCommit(
        path: path,
        fileName: item.fileName,
        isBundle: false,
        artifactPaths: {item.platform: path},
      );
    }

    final platforms = batch.items.map((item) => item.platform).toSet();
    if (!platforms.containsAll(const {'android', 'windows'}) ||
        platforms.length != 2) {
      throw StateError('双目标导出批次无效');
    }
    final archive = Archive();
    for (final item in batch.items) {
      final bytes = await _readVerifiedItem(item, cancellation: cancellation);
      archive.addFile(
        ArchiveFile.noCompress(item.fileName, bytes.length, bytes),
      );
    }
    final manifestBytes = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(batch.safeManifestJson())}\n',
    );
    archive.addFile(
      ArchiveFile.noCompress(
        'manifest.json',
        manifestBytes.length,
        manifestBytes,
      ),
    );
    cancellation?.throwIfCancelled();
    final bundleBytes = await Isolate.run(
      () => Uint8List.fromList(ZipEncoder().encodeBytes(archive)),
    );
    cancellation?.throwIfCancelled();
    final bundleFileName =
        '${batch.projectId}-${batch.versionName}-android-windows.zip';
    cancellation?.beginExternalCommit();
    final path = await _save(
      bytes: bundleBytes,
      fileName: bundleFileName,
      extension: 'zip',
    );
    if (path == null) return null;
    return LibraryArtifactExportCommit(
      path: path,
      fileName: bundleFileName,
      isBundle: true,
    );
  }

  Future<Uint8List> _readVerifiedItem(
    LibraryArtifactExportItem item, {
    LibraryBuildCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final bytes = await File(item.sourcePath).readAsBytes();
    cancellation?.throwIfCancelled();
        if (bytes.length != item.byteLength) {
      throw StateError('待导出产物已发生变化');
    }
    return bytes;
  }

  Future<String?> _save({
    required Uint8List bytes,
    required String fileName,
    required String extension,
  }) async {
    final injectedSaveFile = saveFile;
    if (injectedSaveFile != null) {
      return injectedSaveFile(
        bytes: bytes,
        fileName: fileName,
        extension: extension,
      );
    }
    final injectedPickSavePath = pickSavePath;
    final path = injectedPickSavePath != null
        ? await injectedPickSavePath(fileName: fileName, extension: extension)
        : await FilePicker.saveFile(
            dialogTitle: '导出自定义软件库',
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: [extension],
            bytes: Platform.isWindows ? null : bytes,
            lockParentWindow: true,
          );
    if (path == null) return null;
    if (Platform.isWindows) {
      if (!RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)').hasMatch(path)) {
        throw StateError('导出位置不是本地 Windows 文件路径');
      }
      await _writeBytesAtomically(File(path), bytes);
      return path;
    }
    final uri = Uri.tryParse(path);
    if (uri == null || uri.scheme.isEmpty || uri.scheme == 'file') {
      final file = File(uri?.scheme == 'file' ? uri!.toFilePath() : path);
      await _writeBytesAtomically(file, bytes);
    }
    return path;
  }

  Future<void> _writeBytesAtomically(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    final nonce = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final temporary = File(
      '${target.path}.lanzouyou-${DateTime.now().microsecondsSinceEpoch}-$nonce.tmp',
    );
    try {
            await temporary.writeAsBytes(bytes, flush: true);
      if (await temporary.length() != bytes.length ||
          !_bytesEqual(await temporary.readAsBytes(), bytes)) {
        throw StateError('导出暂存产物校验失败');
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

typedef LibraryDirectoryProvider = Future<Directory> Function();

class LocalTemplateLibraryBuildService implements LibraryBuildService {
  LocalTemplateLibraryBuildService({
    LibraryCoreDispatcher? dispatcher,
    LibraryTemplateLoader? templateLoader,
    LibraryArtifactExporter? artifactExporter,
    LibraryDirectoryProvider? cacheDirectoryProvider,
    LibraryDirectoryProvider? supportDirectoryProvider,
    this.isSupportedHost,
  }) : _dispatcher = dispatcher ?? RustLibraryCoreDispatcher(),
       _templateLoader = templateLoader ?? AssetLibraryTemplateLoader(),
       _artifactExporter =
           artifactExporter ?? const FilePickerLibraryArtifactExporter(),
       _cacheDirectoryProvider =
           cacheDirectoryProvider ?? getTemporaryDirectory,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  final LibraryCoreDispatcher _dispatcher;
  final LibraryTemplateLoader _templateLoader;
  final LibraryArtifactExporter _artifactExporter;
  final LibraryDirectoryProvider _cacheDirectoryProvider;
  final LibraryDirectoryProvider _supportDirectoryProvider;
  final bool? isSupportedHost;

  @override
  bool get canBuild =>
      isSupportedHost ?? (Platform.isAndroid || Platform.isWindows);

  @override
  String get unavailableReason => '本地模板封装仅支持 Android 或 Windows 主机';

  @override
  Future<LibraryBuildResult> build(
    LibraryBuildRecipe recipe, {
    LibraryBuildCancellation? cancellation,
  }) async {
    if (!canBuild) throw UnsupportedError(unavailableReason);
    final errors = recipe.validate();
    if (errors.isNotEmpty) throw FormatException(errors.first);
    cancellation?.throwIfCancelled();

    final cacheDirectory = await _cacheDirectoryProvider();
    final buildRoot = Directory(
      _join(cacheDirectory.path, 'lanzouyou', 'library-builder'),
    ).absolute;
    await buildRoot.create(recursive: true);
    final job = Directory(
      _join(
        buildRoot.path,
        '${recipe.identity.projectId}-${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).absolute;
    await job.create();

    try {
      final targets = recipe.build.targets.toList()
        ..sort((first, second) => first.index.compareTo(second.index));
      final prepared = <_PreparedLibraryBuildArtifact>[];
      for (final target in targets) {
        cancellation?.throwIfCancelled();
        prepared.add(await _repackageTarget(recipe, target, job));
        cancellation?.throwIfCancelled();
      }
      cancellation?.throwIfCancelled();
      final commit = await _artifactExporter.exportBatch(
        LibraryArtifactExportBatch(
          projectId: recipe.identity.projectId,
          versionName: recipe.identity.versionName,
          items: prepared.map((artifact) => artifact.exportItem).toList(),
        ),
        cancellation: cancellation,
      );
      if (commit == null) throw const LibraryBuildCancelled();
      final artifacts = <LibraryBuildArtifact>[
        for (final artifact in prepared)
          LibraryBuildArtifact(
            platform: artifact.target.name,
            path: commit.artifactPaths[artifact.target.name] ?? commit.path,
            fileName: artifact.fileName,
                        bundleEntry: commit.isBundle ? artifact.fileName : null,
            byteLength: artifact.byteLength,
            metadata: artifact.metadata,
          ),
      ];
      return LibraryBuildResult(
        result: 'pass',
        artifacts: artifacts,
        export: LibraryBuildExport(
          path: commit.path,
          fileName: commit.fileName,
          isBundle: commit.isBundle,
        ),
      );
    } finally {
      if (_isDescendant(job.path, buildRoot.path) && await job.exists()) {
        await job.delete(recursive: true);
      }
    }
  }

  Future<_PreparedLibraryBuildArtifact> _repackageTarget(
    LibraryBuildRecipe recipe,
    LibraryTarget target,
    Directory job,
  ) async {
    final isAndroid = target == LibraryTarget.android;
    final extension = isAndroid ? 'apk' : 'zip';
    final template = File(_join(job.path, 'template.$extension'));
    await template.writeAsBytes(
      await _templateLoader.load(target),
      flush: true,
    );

    final fileName =
        '${recipe.identity.projectId}-${recipe.identity.versionName}.$extension';
    final output = File(_join(job.path, fileName)).absolute;
    final request = <String, Object?>{
      'op': isAndroid
          ? 'library_repackage_android'
          : 'library_repackage_windows',
      'templatePath': template.absolute.path,
      'outputPath': output.path,
      'runtimeConfig': recipe.runtimeJson(),
      if (recipe.build.iconSourcePath.trim().isNotEmpty)
        'iconPath': recipe.build.iconSourcePath.trim(),
    };
    if (isAndroid) {
      final support = await _supportDirectoryProvider();
      final signingDirectory = Directory(
        _join(support.path, 'data', 'signing', 'library-builder'),
      );
      await signingDirectory.create(recursive: true);
      request['signingIdentityPath'] = _join(
        signingDirectory.path,
        'android-signing-identity.bin',
      );
    }

    final response = await _dispatcher.dispatch(request);
    final responsePath =
        '${response[isAndroid ? 'apkPath' : 'archivePath'] ?? ''}';
    if (!_samePath(responsePath, output.path) || !await output.exists()) {
      throw StateError('核心未返回预期产物');
    }
    final byteLength = await output.length();
    if (byteLength == 0) throw StateError('核心返回了空产物');

        final rustBytes = (response['bytes'] as num?)?.toInt();
    if (rustBytes == null || rustBytes != byteLength) {
      throw StateError('产物大小校验失败');
    }
    final metadata = isAndroid
        ? _validateAndroidResponse(recipe, response)
        : _validateWindowsResponse(recipe, response);
    return _PreparedLibraryBuildArtifact(
      target: target,
      sourcePath: output.path,
      fileName: fileName,
      extension: extension,
            byteLength: byteLength,
      metadata: metadata,
    );
  }

  Map<String, Object?> _validateAndroidResponse(
    LibraryBuildRecipe recipe,
    Map<String, Object?> response,
  ) {
        final signingVerified = response['signingVerified'] == true;
    final packageName = '${response['packageName'] ?? ''}';
    final versionName = '${response['versionName'] ?? ''}';
    final versionCode = (response['versionCode'] as num?)?.toInt();
    if (!signingVerified ||
        packageName != recipe.identity.applicationId ||
        versionName != recipe.identity.versionName ||
        versionCode != recipe.identity.versionCode) {
      throw StateError('Android 产物身份校验失败');
    }
    return {
      'signingVerified': true,
      'packageName': packageName,
      'versionName': versionName,
      'versionCode': versionCode,
    };
  }

  Map<String, Object?> _validateWindowsResponse(
    LibraryBuildRecipe recipe,
    Map<String, Object?> response,
  ) {
    final exeName = '${response['exeName'] ?? ''}';
    final expected = '${recipe.identity.windowsExeName}.exe';
    if (exeName.toLowerCase() != expected.toLowerCase()) {
      throw StateError('Windows 产物身份校验失败');
    }
    return {'exeName': exeName};
  }
}

class _PreparedLibraryBuildArtifact {
  const _PreparedLibraryBuildArtifact({
    required this.target,
    required this.sourcePath,
    required this.fileName,
    required this.extension,
    required this.byteLength,
    required this.metadata,
  });

  final LibraryTarget target;
  final String sourcePath;
  final String fileName;
  final String extension;
  final int byteLength;
  final Map<String, Object?> metadata;

  LibraryArtifactExportItem get exportItem => LibraryArtifactExportItem(
    platform: target.name,
    sourcePath: sourcePath,
    fileName: fileName,
    extension: extension,
        byteLength: byteLength,
    metadata: metadata,
  );
}

abstract interface class LibraryProjectStore {
  Future<String> save(LibraryBuildRecipe recipe);

  Future<String?> export(LibraryBuildRecipe recipe);
}

abstract interface class LibraryProjectCatalogStore
    implements LibraryProjectStore {
  Future<List<LibraryBuildRecipe>> list();

  Future<LibraryBuildRecipe> load(String projectId);
}

class LocalLibraryProjectStore implements LibraryProjectCatalogStore {
  const LocalLibraryProjectStore({
    this.supportDirectoryProvider = getApplicationSupportDirectory,
  });

  final LibraryDirectoryProvider supportDirectoryProvider;

  Future<Directory> _root() async {
    final support = await supportDirectoryProvider();
    return Directory(_join(support.path, 'data', 'library-projects'));
  }

  @override
  Future<List<LibraryBuildRecipe>> list() async {
    final root = await _root();
    if (!await root.exists()) return const <LibraryBuildRecipe>[];
    final recipes = <LibraryBuildRecipe>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final file = File(_join(entity.path, 'recipe.json'));
      if (!await file.exists()) continue;
      try {
        recipes.add(
          LibraryBuildRecipe.fromJson(
            (jsonDecode(await file.readAsString(encoding: utf8)) as Map)
                .cast<String, Object?>(),
          ),
        );
      } on Object {
        continue;
      }
    }
    recipes.sort(
      (left, right) =>
          left.identity.displayName.compareTo(right.identity.displayName),
    );
    return List.unmodifiable(recipes);
  }

  @override
  Future<LibraryBuildRecipe> load(String projectId) async {
    if (!RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(projectId)) {
      throw const FormatException('项目 ID 无效');
    }
    final root = await _root();
    final file = File(_join(root.path, projectId, 'recipe.json'));
    final decoded = jsonDecode(await file.readAsString(encoding: utf8));
    if (decoded is! Map) throw const FormatException('项目配置无效');
    return LibraryBuildRecipe.fromJson(decoded.cast<String, Object?>());
  }

  @override
  Future<String> save(LibraryBuildRecipe recipe) async {
    final root = await _root();
    final directory = Directory(_join(root.path, recipe.identity.projectId));
    await directory.create(recursive: true);
    final target = File(_join(directory.path, 'recipe.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(recipe.redactedJson()),
      encoding: utf8,
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    return target.path;
  }

  @override
  Future<String?> export(LibraryBuildRecipe recipe) async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert(recipe.redactedJson()),
      ),
    );
    final path = await FilePicker.saveFile(
      dialogTitle: '导出软件库配置',
      fileName: '${recipe.identity.projectId}.library.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: bytes,
      lockParentWindow: true,
    );
    if (path == null) return null;
    final uri = Uri.tryParse(path);
    if (uri == null || uri.scheme.isEmpty || uri.scheme == 'file') {
      final file = File(uri?.scheme == 'file' ? uri!.toFilePath() : path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    return path;
  }
}

String _join(String first, String second, [String? third, String? fourth]) {
  var result = first;
  for (final part in [second, third, fourth]) {
    if (part == null || part.isEmpty) continue;
    result = result.endsWith(Platform.pathSeparator)
        ? '$result$part'
        : '$result${Platform.pathSeparator}$part';
  }
  return result;
}

bool _bytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

bool _samePath(String first, String second) {
  if (first.trim().isEmpty || second.trim().isEmpty) return false;
  return _normalizedPath(first) == _normalizedPath(second);
}

bool _isDescendant(String child, String parent) {
  final normalizedChild = _normalizedPath(child);
  final normalizedParent = _normalizedPath(parent);
  return normalizedChild.startsWith(
    '$normalizedParent${Platform.pathSeparator}',
  );
}

String _normalizedPath(String value) {
  var normalized = File(value).absolute.path.replaceAll(
    Platform.isWindows ? '/' : '\\',
    Platform.pathSeparator,
  );
  while (normalized.endsWith(Platform.pathSeparator)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
