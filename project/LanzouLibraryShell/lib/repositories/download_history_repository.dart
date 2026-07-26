import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/download_history.dart';
import '../services/download_storage_paths.dart';

abstract interface class DownloadHistoryRepository {
  Future<List<DownloadHistoryEntry>> load();

  Future<void> replaceAll(List<DownloadHistoryEntry> entries);

  Future<void> upsert(DownloadHistoryEntry entry);

  Future<void> remove(String id);

  Future<void> clear();
}

class JsonDownloadHistoryRepository implements DownloadHistoryRepository {
  JsonDownloadHistoryRepository({
    required this.paths,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DownloadStoragePaths paths;
  final DateTime Function() _clock;
  List<DownloadHistoryEntry>? _entries;
  Future<void> _serializationTail = Future.value();
  int _temporarySequence = 0;

  @override
  Future<List<DownloadHistoryEntry>> load() => _serialized(() async {
    final entries = await _ensureLoaded();
    return List.unmodifiable(entries);
  });

  @override
  Future<void> replaceAll(List<DownloadHistoryEntry> entries) =>
      _serialized(() async {
        final normalized = _normalize(entries);
        await _write(normalized);
        _entries = normalized;
      });

  @override
  Future<void> upsert(DownloadHistoryEntry entry) => _serialized(() async {
    final entries = List<DownloadHistoryEntry>.from(await _ensureLoaded());
    entries.removeWhere((candidate) => candidate.id == entry.id);
    entries.insert(0, entry);
    final normalized = _normalize(entries);
    await _write(normalized);
    _entries = normalized;
  });

  @override
  Future<void> remove(String id) => _serialized(() async {
    final entries = List<DownloadHistoryEntry>.from(await _ensureLoaded())
      ..removeWhere((candidate) => candidate.id == id);
    final normalized = _normalize(entries);
    await _write(normalized);
    _entries = normalized;
  });

  @override
  Future<void> clear() => replaceAll(const []);

  Future<List<DownloadHistoryEntry>> _ensureLoaded() async {
    final cached = _entries;
    if (cached != null) return cached;
    final historyFile = await paths.historyFile();
    await _recoverInterruptedCommit(historyFile);
    if (!await historyFile.exists()) {
      return _entries = <DownloadHistoryEntry>[];
    }
    try {
      final length = await historyFile.length();
      if (length > _maxHistoryBytes) {
        throw const FormatException('download history is too large');
      }
      final decoded = jsonDecode(await historyFile.readAsString());
      if (decoded is! Map) {
        throw const FormatException('download history root must be an object');
      }
      final root = decoded.cast<String, Object?>();
      if (root.keys.toSet().difference(const {
            'schemaVersion',
            'entries',
          }).isNotEmpty ||
          root['schemaVersion'] != _historySchemaVersion ||
          root['entries'] is! List) {
        throw const FormatException('download history schema is invalid');
      }
      final entries = (root['entries']! as List)
          .map((value) {
            if (value is! Map) {
              throw const FormatException('download history entry is invalid');
            }
            return DownloadHistoryEntry.fromJson(value.cast<String, Object?>());
          })
          .toList(growable: false);
      return _entries = _normalize(entries);
    } on FormatException {
      try {
        await _quarantine(historyFile);
      } on FileSystemException {
        throw const DownloadHistoryFailure(
          'historyUnavailable',
          '无法安全保留损坏的下载记录',
        );
      }
      _entries = <DownloadHistoryEntry>[];
      throw const DownloadHistoryFailure('historyCorrupt', '下载记录已损坏，原文件已安全保留');
    } on FileSystemException {
      throw const DownloadHistoryFailure('historyUnavailable', '无法读取下载记录');
    }
  }

  List<DownloadHistoryEntry> _normalize(
    Iterable<DownloadHistoryEntry> entries,
  ) {
    final byId = <String, DownloadHistoryEntry>{};
    for (final entry in entries) {
      final existing = byId[entry.id];
      if (existing == null || entry.updatedAt.isAfter(existing.updatedAt)) {
        byId[entry.id] = entry;
      }
    }
    final normalized = byId.values.toList()
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    if (normalized.length > _maxHistoryEntries) {
      normalized.removeRange(_maxHistoryEntries, normalized.length);
    }
    return normalized;
  }

  Future<void> _write(List<DownloadHistoryEntry> entries) async {
    final target = await paths.historyFile();
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.$pid.${++_temporarySequence}.tmp');
    final backup = File('${target.path}.bak');
    final content = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': _historySchemaVersion,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    });
    try {
      await temporary.writeAsString(content, flush: true);
      if (await backup.exists()) await backup.delete();
      if (await target.exists()) await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
      } on Object {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete();
    } on FileSystemException {
      throw const DownloadHistoryFailure('historyUnavailable', '无法保存下载记录');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _recoverInterruptedCommit(File target) async {
    final backup = File('${target.path}.bak');
    if (!await backup.exists()) return;
    if (await target.exists()) {
      await backup.delete();
    } else {
      await backup.rename(target.path);
    }
  }

  Future<void> _quarantine(File historyFile) async {
    if (!await historyFile.exists()) return;
    final timestamp = _clock().toUtc().toIso8601String().replaceAll(
      RegExp('[^0-9]'),
      '',
    );
    var candidate = File(
      '${historyFile.parent.path}${Platform.pathSeparator}'
      'downloads.corrupt-$timestamp.json',
    );
    for (var suffix = 1; await candidate.exists(); suffix++) {
      candidate = File(
        '${historyFile.parent.path}${Platform.pathSeparator}'
        'downloads.corrupt-$timestamp-$suffix.json',
      );
    }
    await historyFile.rename(candidate.path);
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _serializationTail;
    final finished = Completer<void>();
    _serializationTail = finished.future;
    return (() async {
      await previous;
      try {
        return await operation();
      } finally {
        finished.complete();
      }
    })();
  }
}

class DownloadHistoryFailure implements Exception {
  const DownloadHistoryFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DownloadHistoryFailure($code): $message';
}

const int _historySchemaVersion = 1;
const int _maxHistoryEntries = 500;
const int _maxHistoryBytes = 4 * 1024 * 1024;
