import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/library_core.dart';

const libraryRemoteImageMaxBytes = 1024 * 1024;
const libraryRemoteTextMaxBytes = 128 * 1024;
const libraryRemoteContentMaxAge = Duration(hours: 24);

abstract interface class LibraryRemoteContentRepository {
  Future<Uint8List> loadImage(String url, {bool refresh = false});

  Future<String> loadText(String url, {bool refresh = false});
}

typedef LibraryRemoteByteLoader = Future<Uint8List> Function(String url);
typedef LibraryRemoteCacheDirectory = Future<Directory> Function();
typedef LibraryRemoteClock = DateTime Function();

class CachedLibraryRemoteContentRepository
    implements LibraryRemoteContentRepository {
  factory CachedLibraryRemoteContentRepository.production({
    required LibraryCore core,
  }) {
    if (core is! LibraryAssetCore) {
      throw ArgumentError.value(core, 'core', '生产 LibraryCore 必须支持远程资源读取');
    }
    final assetCore = core as LibraryAssetCore;
    return CachedLibraryRemoteContentRepository.testHarness(
      cacheDirectory: _productionRemoteCacheDirectory,
      imageLoader: (url) async => (await assetCore.fetchAsset(url: url)).bytes,
      textLoader: (url) async {
        final folder = await core.browse(
          sourceId: 'remote-document',
          shareUrl: url,
          page: 1,
        );
        return Uint8List.fromList(utf8.encode(folder.description));
      },
    );
  }

  @visibleForTesting
  CachedLibraryRemoteContentRepository.testHarness({
    required LibraryRemoteCacheDirectory cacheDirectory,
    required LibraryRemoteByteLoader imageLoader,
    required LibraryRemoteByteLoader textLoader,
    this.maxAge = libraryRemoteContentMaxAge,
    LibraryRemoteClock? clock,
  }) : _cacheDirectory = cacheDirectory,
       _imageLoader = imageLoader,
       _textLoader = textLoader,
       _clock = clock ?? DateTime.now;

  final LibraryRemoteCacheDirectory _cacheDirectory;
  final LibraryRemoteByteLoader _imageLoader;
  final LibraryRemoteByteLoader _textLoader;
  final LibraryRemoteClock _clock;
  final Duration maxAge;
  final Map<String, Future<Uint8List>> _pending = {};

  @override
  Future<Uint8List> loadImage(String url, {bool refresh = false}) async {
    final normalized = _normalizeHttpsUrl(url);
    final bytes = await _loadBytes(
      normalized,
      kind: 'image',
      loader: _imageLoader,
      maxBytes: libraryRemoteImageMaxBytes,
      allowEmpty: false,
      validator: _validatePng,
      refresh: refresh,
    );
    return bytes;
  }

  @override
  Future<String> loadText(String url, {bool refresh = false}) async {
    final normalized = _normalizeHttpsUrl(url);
    final bytes = await _loadBytes(
      normalized,
      kind: 'text',
      loader: _textLoader,
      maxBytes: libraryRemoteTextMaxBytes,
      allowEmpty: true,
      validator: _validateUtf8,
      refresh: refresh,
    );
    final decoded = utf8.decode(bytes, allowMalformed: false);
    return decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
  }

  Future<Uint8List> _loadBytes(
    String url, {
    required String kind,
    required LibraryRemoteByteLoader loader,
    required int maxBytes,
    required bool allowEmpty,
    required void Function(Uint8List) validator,
    required bool refresh,
  }) {
    final requestKey = '$kind:$url:${refresh ? 'refresh' : 'cached'}';
    final existing = _pending[requestKey];
    if (existing != null) return existing;
    final future = _loadBytesUnshared(
      url,
      kind: kind,
      loader: loader,
      maxBytes: maxBytes,
      allowEmpty: allowEmpty,
      validator: validator,
      refresh: refresh,
    );
    _pending[requestKey] = future;
    void clearPending() {
      if (identical(_pending[requestKey], future)) _pending.remove(requestKey);
    }

    future.then<void>((_) => clearPending(), onError: (_, _) => clearPending());
    return future;
  }

  Future<Uint8List> _loadBytesUnshared(
    String url, {
    required String kind,
    required LibraryRemoteByteLoader loader,
    required int maxBytes,
    required bool allowEmpty,
    required void Function(Uint8List) validator,
    required bool refresh,
  }) async {
    final directory = await _cacheDirectory();
    if (directory.path.trim().isEmpty) {
      throw const LibraryRemoteContentFailure(
        'cacheUnavailable',
        '远程内容缓存目录不可用',
      );
    }
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.absolute.path,
        '${sha256.convert(utf8.encode('$kind:$url'))}.bin',
      ),
    );
    final cached = await _readCache(
      file,
      maxBytes: maxBytes,
      allowEmpty: allowEmpty,
      validator: validator,
    );
    if (!refresh &&
        cached != null &&
        _clock().difference((await file.stat()).modified) <= maxAge) {
      return cached;
    }

    try {
      final downloaded = Uint8List.fromList(await loader(url));
      _validateSize(downloaded, maxBytes: maxBytes, allowEmpty: allowEmpty);
      validator(downloaded);
      await _writeAtomically(file, downloaded);
      return downloaded;
    } on LibraryRemoteContentFailure {
      if (cached != null) return cached;
      rethrow;
    } on Object {
      if (cached != null) return cached;
      throw const LibraryRemoteContentFailure(
        'downloadFailed',
        '无法加载远程内容，请稍后重试',
      );
    }
  }

  Future<Uint8List?> _readCache(
    File file, {
    required int maxBytes,
    required bool allowEmpty,
    required void Function(Uint8List) validator,
  }) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > maxBytes ||
          (!allowEmpty && stat.size == 0)) {
        return null;
      }
      final bytes = await file.readAsBytes();
      _validateSize(bytes, maxBytes: maxBytes, allowEmpty: allowEmpty);
      validator(bytes);
      return Uint8List.fromList(bytes);
    } on Object {
      return null;
    }
  }

  Future<void> _writeAtomically(File target, Uint8List bytes) async {
    final temporary = File(
      '${target.path}.tmp-${pid}-${_clock().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // The cache remains usable even when best-effort temp cleanup fails.
      }
      rethrow;
    }
  }
}

class UnavailableLibraryRemoteContentRepository
    implements LibraryRemoteContentRepository {
  const UnavailableLibraryRemoteContentRepository();

  @override
  Future<Uint8List> loadImage(String url, {bool refresh = false}) =>
      Future.error(
        const LibraryRemoteContentFailure('unavailable', '远程内容服务不可用'),
      );

  @override
  Future<String> loadText(String url, {bool refresh = false}) => Future.error(
    const LibraryRemoteContentFailure('unavailable', '远程内容服务不可用'),
  );
}

class LibraryRemoteContentFailure implements Exception {
  const LibraryRemoteContentFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'LibraryRemoteContentFailure($code): $message';
}

Future<Directory> _productionRemoteCacheDirectory() async {
  try {
    final cache = await getApplicationCacheDirectory();
    return Directory(p.join(cache.absolute.path, 'remote_content', 'v1'));
  } on Object {
    final support = await getApplicationSupportDirectory();
    return Directory(
      p.join(support.absolute.path, 'cache', 'remote_content', 'v1'),
    );
  }
}

String _normalizeHttpsUrl(String value) {
  final normalized = value.trim();
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.fragment.isNotEmpty) {
    throw const LibraryRemoteContentFailure(
      'invalidUrl',
      '远程内容地址必须是有效的 HTTPS 地址',
    );
  }
  return uri.toString();
}

void _validateSize(
  Uint8List bytes, {
  required int maxBytes,
  required bool allowEmpty,
}) {
  if (bytes.length > maxBytes || (!allowEmpty && bytes.isEmpty)) {
    throw const LibraryRemoteContentFailure('invalidSize', '远程内容大小超过安全上限');
  }
}

void _validatePng(Uint8List bytes) {
  final isPng =
      bytes.length >= 8 &&
      const [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ].indexed.every((entry) => bytes[entry.$1] == entry.$2);
  if (!isPng) {
    throw const LibraryRemoteContentFailure('invalidImage', '远程图片格式无效');
  }
}

void _validateUtf8(Uint8List bytes) {
  try {
    utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const LibraryRemoteContentFailure(
      'invalidUtf8',
      '远程公告不是有效的 UTF-8 文本',
    );
  }
}
