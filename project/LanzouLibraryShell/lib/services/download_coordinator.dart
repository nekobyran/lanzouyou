import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/download_history.dart';
import '../repositories/download_history_repository.dart';
import 'download_file_opener.dart';
import 'download_storage_paths.dart';
import 'library_core.dart';

class DownloadCoordinator extends ChangeNotifier {
  factory DownloadCoordinator.production({
    required LibraryDownloadRuntime core,
  }) {
    final paths = PathProviderDownloadStoragePaths.production();
    return DownloadCoordinator(
      downloadCore: core,
      operationCore: core,
      repository: JsonDownloadHistoryRepository(paths: paths),
      paths: paths,
      fileOpener: OpenFilexDownloadFileOpener.production(),
    );
  }

  DownloadCoordinator({
    required this.downloadCore,
    required this.operationCore,
    required this.repository,
    required this.paths,
    required this.fileOpener,
    this.operationIdFactory,
    DateTime Function()? clock,
    this.pollInitialDelay = const Duration(milliseconds: 160),
    this.pollMaxDelay = const Duration(milliseconds: 400),
    this.controlTimeout = const Duration(seconds: 2),
    this.shutdownTimeout = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now;

  final LibraryDownloadCore downloadCore;
  final LibraryOperationCore operationCore;
  final DownloadHistoryRepository repository;
  final DownloadStoragePaths paths;
  final DownloadFileOpener fileOpener;
  final String Function()? operationIdFactory;
  final DateTime Function() _clock;
  final Duration pollInitialDelay;
  final Duration pollMaxDelay;
  final Duration controlTimeout;
  final Duration shutdownTimeout;

  final Queue<_QueuedDownload> _queue = Queue();
  final LinkedHashMap<String, DownloadSnapshot> _activities = LinkedHashMap();
  final Map<String, DateTime> _lastProgressPersistAt = {};
  final Map<String, int> _lastProgressPersistBytes = {};
  final Map<String, _DownloadSpeedSample> _speedSamples = {};
  List<DownloadHistoryEntry> _history = const [];
  Future<void>? _initializeFuture;
  Future<void>? _shutdownFuture;
  Future<void>? _runningTask;
  _QueuedDownload? _runningRequest;
  String _saveDirectory = '';
  String _loadError = '';
  String _persistenceWarning = '';
  int _operationSequence = 0;
  bool _isLoading = true;
  bool _initialized = false;
  bool _initializationFailed = false;
  bool _shuttingDown = false;
  bool _disposed = false;

  List<DownloadHistoryEntry> get history => List.unmodifiable(_history);

  List<DownloadSnapshot> get active => List.unmodifiable(_activities.values);

  bool get isLoading => _isLoading;

  String get loadError => _loadError;

  String get persistenceWarning => _persistenceWarning;

  String get saveDirectory => _saveDirectory;

  Future<void> initialize() {
    final current = _initializeFuture;
    if (_isLoading && current != null) return current;
    if (_initialized && !_initializationFailed) return Future.value();
    return _initializeFuture = _initialize();
  }

  Future<void> _initialize() async {
    if (_activities.isNotEmpty) return;
    _isLoading = true;
    _loadError = '';
    notifyListeners();
    Object? pathError;
    Object? historyError;
    var repaired = false;
    try {
      _saveDirectory = await paths.downloadsDirectory();
    } on Object catch (error) {
      pathError = error;
    }
    try {
      final loaded = await repository.load();
      final now = _now();
      final normalized = loaded
          .map((entry) {
            if (entry.status.isTerminal) return entry;
            repaired = true;
            return entry.copyWith(
              status: DownloadHistoryStatus.failed,
              updatedAt: now,
              completedAt: now,
              errorCode: 'interrupted',
              errorMessage: '上次下载未完成，可以重试',
            );
          })
          .toList(growable: false);
      _history = _sortedHistory(normalized);
    } on Object catch (error) {
      historyError = error;
      _history = const [];
    }
    if (historyError == null && repaired) {
      await _safeRepositoryCall(() => repository.replaceAll(_history));
    }
    if (pathError != null) {
      _loadError = '无法读取系统下载目录';
    } else if (historyError != null) {
      _loadError = historyError is DownloadHistoryFailure
          ? historyError.message
          : '无法读取下载记录';
    }
    _initialized = true;
    _initializationFailed = pathError != null || historyError != null;
    _isLoading = false;
    notifyListeners();
  }

  Future<String> download({
    required String sourceId,
    required String shareUrl,
    required String password,
    required String itemStableKey,
    required String displayName,
    String suggestedFileName = '',
  }) async {
    if (_shuttingDown) {
      throw const DownloadCoordinatorFailure('shuttingDown', '下载服务正在关闭');
    }
    await initialize();
    if (_shuttingDown) {
      throw const DownloadCoordinatorFailure('shuttingDown', '下载服务正在关闭');
    }
    if (_queue.length + (_runningRequest == null ? 0 : 1) >= _maxQueuedTasks) {
      throw const DownloadCoordinatorFailure('queueFull', '下载队列已满');
    }
    final normalizedSourceId = sourceId.trim();
    final normalizedUrl = shareUrl.trim();
    final normalizedItemKey = itemStableKey.trim();
    final normalizedDisplayName = displayName.trim();
    if (normalizedSourceId.isEmpty ||
        !isSafeDownloadShareUrl(normalizedUrl) ||
        normalizedItemKey.isEmpty ||
        normalizedDisplayName.isEmpty) {
      throw const DownloadCoordinatorFailure('invalidRequest', '下载项目无效');
    }
    if (_activities.values.any(
      (activity) => activity.itemStableKey == normalizedItemKey,
    )) {
      throw const DownloadCoordinatorFailure('alreadyQueued', '此项目已在下载队列中');
    }
    final operationId = _newOperationId();
    final now = _now();
    final entry = DownloadHistoryEntry(
      id: operationId,
      operationId: operationId,
      sourceId: normalizedSourceId,
      shareUrl: normalizedUrl,
      itemStableKey: normalizedItemKey,
      displayName: normalizedDisplayName,
      suggestedFileName: suggestedFileName.trim(),
      filePath: '',
      status: DownloadHistoryStatus.queued,
      bytesTransferred: 0,
      totalBytes: 0,
      createdAt: now,
      updatedAt: now,
    );
    _upsertHistoryInMemory(entry);
    _activities[operationId] = DownloadSnapshot(
      operationId: operationId,
      historyId: operationId,
      itemStableKey: normalizedItemKey,
      fileName: suggestedFileName.trim().isEmpty
          ? normalizedDisplayName
          : suggestedFileName.trim(),
      state: DownloadActivityState.queued,
      bytesTransferred: 0,
      totalBytes: 0,
    );
    _speedSamples[operationId] = _DownloadSpeedSample(now, 0);
    final request = _QueuedDownload(
      operationId: operationId,
      sourceId: normalizedSourceId,
      shareUrl: normalizedUrl,
      password: password,
    );
    request.persisted = _persistEntry(entry);
    _queue.add(request);
    notifyListeners();
    _pumpQueue();
    return operationId;
  }

  Future<String> retry(
    DownloadHistoryEntry entry, {
    required String password,
  }) => download(
    sourceId: entry.sourceId,
    shareUrl: entry.shareUrl,
    password: password,
    itemStableKey: entry.itemStableKey,
    displayName: entry.displayName,
    suggestedFileName: entry.suggestedFileName,
  );

  Future<void> cancel(String operationId) async {
    final queued = _queue.where(
      (request) => request.operationId == operationId,
    );
    if (queued.isNotEmpty) {
      final request = queued.single;
      request.cancelRequested = true;
      _queue.remove(request);
      await request.persisted;
      await _finishTerminal(
        request,
        historyStatus: DownloadHistoryStatus.cancelled,
        activityState: DownloadActivityState.cancelled,
        errorCode: 'cancelled',
        safeError: '已取消下载',
      );
      request.clearSecret();
      _pumpQueue();
      return;
    }
    final request = _runningRequest;
    if (request == null || request.operationId != operationId) return;
    final previousSnapshot = _activities[operationId];
    final previousHistoryStatus = _historyById(operationId)?.status;
    request.cancelRequested = true;
    await _setState(
      request,
      historyStatus: DownloadHistoryStatus.cancelling,
      activityState: DownloadActivityState.cancelling,
      persist: true,
    );
    try {
      await _requestCancellation(request);
    } on Object {
      if (identical(_runningRequest, request)) {
        request.cancelRequested = false;
        final currentSnapshot = _activities[operationId];
        final transferStarted =
            currentSnapshot != null &&
            (currentSnapshot.bytesTransferred > 0 ||
                currentSnapshot.totalBytes > 0);
        final restoreResolving =
            previousSnapshot?.state == DownloadActivityState.resolving &&
            previousHistoryStatus == DownloadHistoryStatus.resolving &&
            !transferStarted;
        await _setState(
          request,
          historyStatus: restoreResolving
              ? DownloadHistoryStatus.resolving
              : DownloadHistoryStatus.downloading,
          activityState: restoreResolving
              ? DownloadActivityState.resolving
              : DownloadActivityState.downloading,
          persist: true,
        );
      }
      rethrow;
    }
  }

  Future<void> open(DownloadHistoryEntry entry) async {
    if (entry.status != DownloadHistoryStatus.succeeded ||
        entry.filePath.isEmpty) {
      throw const DownloadCoordinatorFailure('notCompleted', '下载尚未完成');
    }
    final directory = await _resolveSaveDirectory();
    if (!await File(entry.filePath).exists()) {
      throw const DownloadCoordinatorFailure('fileNotFound', '下载文件已不存在');
    }
    if (!_isPathInsideDirectory(directory, entry.filePath) ||
        !await _isCanonicalPathInsideDirectory(directory, entry.filePath)) {
      throw const DownloadCoordinatorFailure('unsafePath', '下载文件路径不安全');
    }
    try {
      await fileOpener.open(entry.filePath);
    } on DownloadFileOpenFailure catch (error) {
      throw DownloadCoordinatorFailure(error.code, error.message);
    }
  }

  Future<void> deleteHistory(String id) async {
    if (_activities.containsKey(id)) {
      throw const DownloadCoordinatorFailure('downloadActive', '请先取消正在进行的下载');
    }
    _history = _history.where((entry) => entry.id != id).toList();
    notifyListeners();
    await _safeRepositoryCall(() => repository.remove(id));
  }

  /// Deletes a completed local file and then removes its matching history row.
  ///
  /// The canonical-path check prevents a persisted or tampered history entry
  /// from deleting a file outside the real system Downloads directory.
  Future<void> deleteFileAndHistory(DownloadHistoryEntry entry) async {
    if (_activities.containsKey(entry.id)) {
      throw const DownloadCoordinatorFailure('downloadActive', '请先取消正在进行的下载');
    }
    if (entry.status != DownloadHistoryStatus.succeeded ||
        entry.filePath.trim().isEmpty) {
      throw const DownloadCoordinatorFailure('notCompleted', '下载尚未完成');
    }
    final directory = await _resolveSaveDirectory();
    final file = File(entry.filePath);
    if (!await file.exists()) {
      throw const DownloadCoordinatorFailure('fileNotFound', '下载文件已不存在');
    }
    if (!_isPathInsideDirectory(directory, entry.filePath) ||
        !await _isCanonicalPathInsideDirectory(directory, entry.filePath)) {
      throw const DownloadCoordinatorFailure('unsafePath', '下载文件路径不安全');
    }
    try {
      await file.delete();
    } on FileSystemException {
      throw const DownloadCoordinatorFailure('deleteFailed', '无法删除下载文件');
    }
    _history = _history
        .where((candidate) => candidate.id != entry.id)
        .toList(growable: false);
    notifyListeners();
    await _safeRepositoryCall(() => repository.remove(entry.id));
  }

  Future<void> clearHistory() async {
    final activeIds = _activities.keys.toSet();
    _history = _history
        .where((entry) => activeIds.contains(entry.id))
        .toList(growable: false);
    notifyListeners();
    await _safeRepositoryCall(() => repository.replaceAll(_history));
  }

  Future<void> shutdown() => _shutdownFuture ??= _performShutdown();

  Future<void> _performShutdown() async {
    _shuttingDown = true;
    Object? cancellationError;
    for (final request in List<_QueuedDownload>.from(_queue)) {
      try {
        await cancel(request.operationId);
      } on Object catch (error) {
        cancellationError ??= error;
      }
    }
    final running = _runningRequest;
    if (running != null) {
      try {
        await cancel(running.operationId);
      } on Object catch (error) {
        cancellationError ??= error;
      }
    }
    final task = _runningTask;
    if (task != null) {
      try {
        await task.timeout(shutdownTimeout);
      } on TimeoutException {
        throw const DownloadCoordinatorFailure('shutdownTimeout', '等待下载清理超时');
      }
    }
    if (_activities.isNotEmpty && cancellationError != null) {
      throw const DownloadCoordinatorFailure('cancelFailed', '无法完成下载清理');
    }
  }

  void _pumpQueue() {
    if (_shuttingDown || _runningRequest != null || _queue.isEmpty) return;
    final request = _queue.removeFirst();
    _runningRequest = request;
    late final Future<void> task;
    task = _execute(request).whenComplete(() {
      if (identical(_runningTask, task)) _runningTask = null;
      if (identical(_runningRequest, request)) _runningRequest = null;
      request.clearSecret();
      _lastProgressPersistAt.remove(request.operationId);
      _lastProgressPersistBytes.remove(request.operationId);
      _speedSamples.remove(request.operationId);
      _pumpQueue();
    });
    _runningTask = task;
    unawaited(task);
  }

  Future<void> _execute(_QueuedDownload request) async {
    await request.persisted;
    if (request.cancelRequested || _shuttingDown) {
      await _finishTerminal(
        request,
        historyStatus: DownloadHistoryStatus.cancelled,
        activityState: DownloadActivityState.cancelled,
        errorCode: 'cancelled',
        safeError: '已取消下载',
      );
      return;
    }
    await _setState(
      request,
      historyStatus: DownloadHistoryStatus.resolving,
      activityState: DownloadActivityState.resolving,
      persist: true,
    );
    try {
      final destinationDirectory = await _resolveSaveDirectory();
      if (request.cancelRequested || _shuttingDown) {
        await _finishTerminal(
          request,
          historyStatus: DownloadHistoryStatus.cancelled,
          activityState: DownloadActivityState.cancelled,
          errorCode: 'cancelled',
          safeError: '已取消下载',
        );
        return;
      }
      final completion = downloadCore.download(
        sourceId: request.sourceId,
        shareUrl: request.shareUrl,
        password: request.password,
        destinationDirectory: destinationDirectory,
        operationId: request.operationId,
      );
      unawaited(_pollProgress(request));
      if (request.cancelRequested || _shuttingDown) {
        unawaited(_requestCancellation(request));
      }
      final result = await completion;
      if (!_isPathInsideDirectory(destinationDirectory, result.path)) {
        throw const DownloadCoordinatorFailure(
          'unsafeResponse',
          '核心返回了不安全的下载路径',
        );
      }
      await _finishTerminal(
        request,
        historyStatus: DownloadHistoryStatus.succeeded,
        activityState: DownloadActivityState.succeeded,
        filePath: p.normalize(result.path),
        fileName: result.fileName,
        bytesTransferred: result.bytesWritten,
        totalBytes: result.bytesWritten,
      );
    } on Object catch (error) {
      final cancelled =
          request.cancelRequested ||
          (error is LibraryCoreFailure && error.code == 'cancelled');
      await _finishTerminal(
        request,
        historyStatus: cancelled
            ? DownloadHistoryStatus.cancelled
            : DownloadHistoryStatus.failed,
        activityState: cancelled
            ? DownloadActivityState.cancelled
            : DownloadActivityState.failed,
        errorCode: cancelled ? 'cancelled' : _safeErrorCode(error),
        safeError: cancelled ? '已取消下载' : _safeErrorMessage(error),
      );
    } finally {
      await _forgetOperation(request.operationId);
    }
  }

  Future<void> _pollProgress(_QueuedDownload request) async {
    var delay = pollInitialDelay;
    while (identical(_runningRequest, request)) {
      await Future<void>.delayed(delay);
      final snapshot = _activities[request.operationId];
      if (snapshot == null || snapshot.state.isTerminal) return;
      try {
        final status = await operationCore
            .operationStatus(request.operationId)
            .timeout(controlTimeout);
        if (!identical(_runningRequest, request) ||
            status.operationId != request.operationId ||
            status.kind != 'download') {
          return;
        }
        final cancelling =
            request.cancelRequested ||
            snapshot.state == DownloadActivityState.cancelling ||
            status.state == LibraryOperationState.cancelling ||
            status.state == LibraryOperationState.cancelled;
        final transferStarted =
            status.bytesTransferred > 0 || status.totalBytes > 0;
        final state = cancelling
            ? DownloadActivityState.cancelling
            : snapshot.state == DownloadActivityState.resolving &&
                  !transferStarted
            ? DownloadActivityState.resolving
            : DownloadActivityState.downloading;
        final changed =
            snapshot.state != state ||
            snapshot.bytesTransferred != status.bytesTransferred ||
            snapshot.totalBytes != status.totalBytes;
        if (changed) {
          final shouldPersist = _shouldPersistProgress(
            request.operationId,
            state: state,
            previousState: snapshot.state,
            bytesTransferred: status.bytesTransferred,
          );
          await _setState(
            request,
            historyStatus: switch (state) {
              DownloadActivityState.resolving =>
                DownloadHistoryStatus.resolving,
              DownloadActivityState.cancelling =>
                DownloadHistoryStatus.cancelling,
              _ => DownloadHistoryStatus.downloading,
            },
            activityState: state,
            bytesTransferred: status.bytesTransferred,
            totalBytes: status.totalBytes,
            persist: shouldPersist,
          );
          delay = pollInitialDelay;
        } else {
          delay += const Duration(milliseconds: 80);
          if (delay > pollMaxDelay) delay = pollMaxDelay;
        }
      } on Object {
        delay = pollMaxDelay;
      }
    }
  }

  bool _shouldPersistProgress(
    String operationId, {
    required DownloadActivityState state,
    required DownloadActivityState previousState,
    required int bytesTransferred,
  }) {
    final now = _now();
    final previousAt = _lastProgressPersistAt[operationId];
    final previousBytes = _lastProgressPersistBytes[operationId] ?? 0;
    final stateChanged = state != previousState;
    final elapsed = previousAt == null ? null : now.difference(previousAt);
    final shouldPersist =
        stateChanged ||
        previousAt == null ||
        elapsed! >= _progressPersistInterval ||
        bytesTransferred - previousBytes >= _progressPersistByteStep;
    if (shouldPersist) {
      _lastProgressPersistAt[operationId] = now;
      _lastProgressPersistBytes[operationId] = bytesTransferred;
    }
    return shouldPersist;
  }

  Future<void> _setState(
    _QueuedDownload request, {
    required DownloadHistoryStatus historyStatus,
    required DownloadActivityState activityState,
    int? bytesTransferred,
    int? totalBytes,
    required bool persist,
  }) async {
    final snapshot = _activities[request.operationId];
    final historyEntry = _historyById(request.operationId);
    if (snapshot == null || historyEntry == null) return;
    final nextBytes = bytesTransferred == null
        ? snapshot.bytesTransferred
        : bytesTransferred < snapshot.bytesTransferred
        ? snapshot.bytesTransferred
        : bytesTransferred;
    final nextTotal = totalBytes == null
        ? snapshot.totalBytes
        : totalBytes < snapshot.totalBytes
        ? snapshot.totalBytes
        : totalBytes;
    final now = _now();
    final nextSpeed = activityState == DownloadActivityState.downloading
        ? _measureSpeed(
            request.operationId,
            now: now,
            bytesTransferred: nextBytes,
            currentBytesPerSecond: snapshot.bytesPerSecond,
          )
        : 0;
    _activities[request.operationId] = snapshot.copyWith(
      state: activityState,
      bytesTransferred: nextBytes,
      totalBytes: nextTotal,
      bytesPerSecond: nextSpeed,
    );
    final updated = historyEntry.copyWith(
      status: historyStatus,
      bytesTransferred: nextBytes,
      totalBytes: nextTotal,
      updatedAt: now,
    );
    _upsertHistoryInMemory(updated);
    notifyListeners();
    if (persist) await _persistEntry(updated);
  }

  Future<void> _finishTerminal(
    _QueuedDownload request, {
    required DownloadHistoryStatus historyStatus,
    required DownloadActivityState activityState,
    String filePath = '',
    String? fileName,
    int? bytesTransferred,
    int? totalBytes,
    String errorCode = '',
    String safeError = '',
  }) async {
    final snapshot = _activities[request.operationId];
    final historyEntry = _historyById(request.operationId);
    if (snapshot == null || historyEntry == null) return;
    final now = _now();
    final nextBytes = bytesTransferred ?? snapshot.bytesTransferred;
    final nextTotal = totalBytes ?? snapshot.totalBytes;
    _activities[request.operationId] = snapshot.copyWith(
      fileName: fileName,
      state: activityState,
      bytesTransferred: nextBytes,
      totalBytes: nextTotal,
      filePath: filePath,
      safeError: safeError,
      bytesPerSecond: 0,
    );
    final updated = historyEntry.copyWith(
      filePath: filePath,
      status: historyStatus,
      bytesTransferred: nextBytes,
      totalBytes: nextTotal,
      updatedAt: now,
      completedAt: now,
      errorCode: errorCode,
      errorMessage: safeError,
    );
    _upsertHistoryInMemory(updated);
    notifyListeners();
    await _persistEntry(updated);
    _activities.remove(request.operationId);
    _speedSamples.remove(request.operationId);
    notifyListeners();
  }

  int _measureSpeed(
    String operationId, {
    required DateTime now,
    required int bytesTransferred,
    required int currentBytesPerSecond,
  }) {
    final previous = _speedSamples[operationId];
    if (previous == null) {
      _speedSamples[operationId] = _DownloadSpeedSample(now, bytesTransferred);
      return currentBytesPerSecond;
    }
    if (bytesTransferred <= previous.bytesTransferred) {
      return currentBytesPerSecond;
    }
    final elapsedMicros = now.difference(previous.at).inMicroseconds;
    _speedSamples[operationId] = _DownloadSpeedSample(now, bytesTransferred);
    if (elapsedMicros <= 0) return currentBytesPerSecond;
    final measured =
        ((bytesTransferred - previous.bytesTransferred) *
                Duration.microsecondsPerSecond /
                elapsedMicros)
            .round();
    if (measured <= 0) return currentBytesPerSecond;
    if (currentBytesPerSecond <= 0) return measured;
    return ((currentBytesPerSecond * 3 + measured) / 4).round();
  }

  Future<void> _requestCancellation(_QueuedDownload request) async {
    for (
      var attempt = 0;
      attempt <= _registrationRetryDelays.length;
      attempt++
    ) {
      if (!identical(_runningRequest, request)) return;
      try {
        await operationCore
            .cancelOperation(request.operationId)
            .timeout(controlTimeout);
        return;
      } on LibraryCoreFailure catch (error) {
        if (error.code != 'operation_not_found' ||
            attempt >= _registrationRetryDelays.length) {
          throw const DownloadCoordinatorFailure('cancelFailed', '无法取消当前下载');
        }
        await Future<void>.delayed(_registrationRetryDelays[attempt]);
      } on Object {
        throw const DownloadCoordinatorFailure('cancelFailed', '无法取消当前下载');
      }
    }
  }

  Future<void> _forgetOperation(String operationId) async {
    try {
      await operationCore.forgetOperation(operationId).timeout(controlTimeout);
    } on Object {
      // The bounded native registry also evicts terminal operations.
    }
  }

  Future<String> _resolveSaveDirectory() async {
    if (_saveDirectory.isNotEmpty) return _saveDirectory;
    try {
      _saveDirectory = await paths.downloadsDirectory();
      notifyListeners();
      return _saveDirectory;
    } on Object {
      throw const DownloadCoordinatorFailure(
        'downloadsUnavailable',
        '系统下载目录不可用',
      );
    }
  }

  bool _isPathInsideDirectory(String directory, String filePath) {
    final root = p.normalize(p.absolute(directory));
    final candidate = p.normalize(p.absolute(filePath));
    return p.isWithin(root, candidate);
  }

  Future<bool> _isCanonicalPathInsideDirectory(
    String directory,
    String filePath,
  ) async {
    try {
      final root = p.normalize(
        await Directory(directory).resolveSymbolicLinks(),
      );
      final candidate = p.normalize(
        await File(filePath).resolveSymbolicLinks(),
      );
      return p.isWithin(root, candidate);
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _persistEntry(DownloadHistoryEntry entry) =>
      _safeRepositoryCall(() => repository.upsert(entry));

  Future<void> _safeRepositoryCall(Future<void> Function() operation) async {
    try {
      await operation();
      if (_persistenceWarning.isNotEmpty) {
        _persistenceWarning = '';
        notifyListeners();
      }
    } on Object {
      if (_persistenceWarning != '无法保存下载记录') {
        _persistenceWarning = '无法保存下载记录';
        notifyListeners();
      }
    }
  }

  void _upsertHistoryInMemory(DownloadHistoryEntry entry) {
    _history = _sortedHistory([
      entry,
      ..._history.where((candidate) => candidate.id != entry.id),
    ]);
  }

  List<DownloadHistoryEntry> _sortedHistory(
    Iterable<DownloadHistoryEntry> entries,
  ) =>
      (entries.toList()
        ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt)));

  DownloadHistoryEntry? _historyById(String id) {
    for (final entry in _history) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  String _newOperationId() {
    final custom = operationIdFactory?.call();
    final operationId =
        custom ??
        'library-download-${_now().microsecondsSinceEpoch.toRadixString(36)}-'
            '${(++_operationSequence).toRadixString(36)}';
    if (!_operationIdPattern.hasMatch(operationId) ||
        _activities.containsKey(operationId) ||
        _history.any((entry) => entry.id == operationId)) {
      throw const DownloadCoordinatorFailure('invalidOperationId', '无法创建下载任务');
    }
    return operationId;
  }

  DateTime _now() => _clock().toUtc();

  String _safeErrorCode(Object error) {
    if (error is LibraryCoreFailure &&
        _safeErrorCodePattern.hasMatch(error.code)) {
      return error.code;
    }
    if (error is DownloadCoordinatorFailure) return error.code;
    if (error is DownloadStorageFailure) return error.code;
    return 'downloadFailed';
  }

  String _safeErrorMessage(Object error) => switch (error) {
    LibraryCoreFailure(code: 'already_exists') => '同名文件已存在，请先处理后重试',
    LibraryCoreFailure(code: 'coreUnavailable') => '下载核心暂不可用，请稍后重试',
    LibraryCoreFailure(code: 'network') => '网络连接失败，请稍后重试',
    LibraryCoreFailure(code: 'atomic_publish_unsupported') =>
      '当前保存位置不支持安全写入，请更换目录',
    DownloadCoordinatorFailure() => error.message,
    DownloadStorageFailure() => error.message,
    _ => '下载失败，请稍后重试',
  };

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (_shutdownFuture == null) unawaited(shutdown());
    _disposed = true;
    super.dispose();
  }
}

class DownloadCoordinatorFailure implements Exception {
  const DownloadCoordinatorFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DownloadCoordinatorFailure($code): $message';
}

class _QueuedDownload {
  _QueuedDownload({
    required this.operationId,
    required this.sourceId,
    required this.shareUrl,
    required this.password,
  });

  final String operationId;
  final String sourceId;
  final String shareUrl;
  String password;
  bool cancelRequested = false;
  Future<void> persisted = Future.value();

  void clearSecret() => password = '';
}

class _DownloadSpeedSample {
  const _DownloadSpeedSample(this.at, this.bytesTransferred);

  final DateTime at;
  final int bytesTransferred;
}

final RegExp _operationIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final RegExp _safeErrorCodePattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
const int _maxQueuedTasks = 64;
const Duration _progressPersistInterval = Duration(seconds: 2);
const int _progressPersistByteStep = 4 * 1024 * 1024;
const List<Duration> _registrationRetryDelays = [
  Duration(milliseconds: 80),
  Duration(milliseconds: 160),
  Duration(milliseconds: 320),
];
