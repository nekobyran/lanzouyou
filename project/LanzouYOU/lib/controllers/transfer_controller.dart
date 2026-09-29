import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/cloud_item.dart';
import '../models/directory_upload.dart';
import '../models/transfer_entry.dart';
import '../services/cloud_service.dart';

typedef TransferOperationIdFactory =
    String Function(TransferKind kind, int sequence);

class TransferController extends ChangeNotifier {
  TransferController(
    this.cloudService, {
    this.operationPollInterval = const Duration(milliseconds: 250),
    TransferOperationIdFactory? operationIdFactory,
  }) : _operationIdFactory = operationIdFactory ?? _defaultOperationId;

  final CloudService cloudService;
  final Duration operationPollInterval;
  final TransferOperationIdFactory _operationIdFactory;
  final List<TransferEntry> _entries = <TransferEntry>[];
  final Queue<_TransferJob> _queue = Queue<_TransferJob>();
  final Map<int, Completer<bool>> _cancelDecisions = <int, Completer<bool>>{};
  final Map<int, _IconRetry> _iconRetries = <int, _IconRetry>{};
  final Map<int, _TransferJob> _activeJobs = <int, _TransferJob>{};
  final Map<int, _OperationPoller> _activePollers = <int, _OperationPoller>{};
  int _nextId = 1;
  int? _transferCapacity;
  Future<int>? _transferCapacityFuture;
  bool _admitting = false;
  bool _disposed = false;

  List<TransferEntry> get entries => List.unmodifiable(_entries);
  bool get hasRunning => _entries.any(
    (entry) =>
        entry.state == TransferState.running ||
        entry.state == TransferState.paused ||
        entry.state == TransferState.cancelling,
  );

  void enqueueUploads({
    required String folderId,
    required Iterable<String> paths,
    required VoidCallback onFolderChanged,
  }) {
    enqueueUploadRequests(
      folderId: folderId,
      requests: paths.map((path) => UploadRequest(path: path)),
      onFolderChanged: onFolderChanged,
    );
  }

  void enqueueUploadRequests({
    required String folderId,
    required Iterable<UploadRequest> requests,
    required VoidCallback onFolderChanged,
  }) {
    for (final request in requests) {
      final id = _nextId++;
      final operationId = _newOperationId(TransferKind.upload, id);
      final entry = TransferEntry(
        id: id,
        name: request.displayName ?? _fileName(request.path),
        kind: TransferKind.upload,
        state: TransferState.queued,
        createdAt: DateTime.now(),
        operationId: operationId,
      );
      _entries.insert(0, entry);
      _queue.add(
        _TransferJob(
          entry.id,
          operationId,
          () => _runUpload(
            entry.id,
            operationId,
            folderId,
            request,
            onFolderChanged,
          ),
          onFolderChanged,
        ),
      );
    }
    _notify();
    _drain();
  }

  void enqueueDownload({required CloudItem item, required String destination}) {
    final id = _nextId++;
    final operationId = _newOperationId(TransferKind.download, id);
    final entry = TransferEntry(
      id: id,
      name: item.name,
      kind: TransferKind.download,
      state: TransferState.queued,
      createdAt: DateTime.now(),
      operationId: operationId,
    );
    _entries.insert(0, entry);
    _queue.add(
      _TransferJob(entry.id, operationId, () async {
        await _throwIfCancellationRequested(entry.id);
        _setStage(entry.id, TransferStage.transferring, message: '正在下载文件');
        await cloudService.download(
          item,
          destination,
          operationId: operationId,
        );
        return null;
      }, () {}),
    );
    _notify();
    _drain();
  }

  void enqueueDirectoryUpload({
    required String folderId,
    required DirectoryUploadRequest request,
    required VoidCallback onFolderChanged,
  }) {
    final id = _nextId++;
    final operationId = _newOperationId(TransferKind.directoryUpload, id);
    final entry = TransferEntry(
      id: id,
      name: request.displayName ?? _fileName(request.path),
      kind: TransferKind.directoryUpload,
      state: TransferState.queued,
      createdAt: DateTime.now(),
      operationId: operationId,
    );
    _entries.insert(0, entry);
    _queue.add(
      _TransferJob(
        entry.id,
        operationId,
        () => _runDirectoryUpload(entry.id, operationId, folderId, request),
        onFolderChanged,
      ),
    );
    _notify();
    _drain();
  }

  Future<String?> _runDirectoryUpload(
    int entryId,
    String operationId,
    String folderId,
    DirectoryUploadRequest request,
  ) async {
    await _throwIfCancellationRequested(entryId);
    _setStage(entryId, TransferStage.transferring, message: '正在安全扫描并保留层级上传文件夹');
    final result = await cloudService.uploadDirectory(
      folderId,
      request.path,
      compatibilityWrap: request.compatibilityWrap,
      kind: request.kind,
      autoApkIcons: request.autoApkIcons,
      operationId: operationId,
    );
    _setDirectoryUploadResult(entryId, result);
    if (result.state == DirectoryUploadState.cancelled) {
      throw _DirectoryUploadCancelled(result);
    }
    return result.state == DirectoryUploadState.partial ? result.summary : null;
  }

  bool retryIconBinding(int id) {
    final retry = _iconRetries[id];
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (retry == null ||
        index < 0 ||
        _entries[index].state != TransferState.succeededWithWarning) {
      return false;
    }
    final entry = _entries[index];
    _entries[index] = entry.copyWith(
      state: TransferState.queued,
      stage: TransferStage.waiting,
      cancelRequested: false,
      errorMessage: '等待重试图标绑定',
      iconRetryAvailable: true,
    );
    _queue.add(
      _TransferJob(
        entry.id,
        entry.operationId,
        () => _runIconRetry(entry.id, retry),
        retry.onFolderChanged,
      ),
    );
    _notify();
    _drain();
    return true;
  }

  bool cancelQueued(int id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || _entries[index].state != TransferState.queued) {
      return false;
    }
    final entry = _entries[index];
    if (_iconRetries.containsKey(id)) {
      _entries[index] = entry.copyWith(
        state: TransferState.succeededWithWarning,
        stage: TransferStage.finished,
        cancelRequested: false,
        errorMessage: 'APK 已上传；已取消图标绑定重试，可再次重试图标绑定',
        iconRetryAvailable: true,
      );
      _queue.removeWhere((job) => job.id == id);
      _notify();
      return true;
    }
    _entries[index] = entry.copyWith(
      state: TransferState.cancelled,
      stage: TransferStage.finished,
      cancelRequested: true,
      errorMessage: null,
    );
    _queue.removeWhere((job) => job.id == id);
    _notify();
    unawaited(_forgetOperation(entry.operationId));
    return true;
  }

  bool canPause(int id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || cloudService is! CloudOperationPauseResume) return false;
    final entry = _entries[index];
    return entry.state == TransferState.running &&
        entry.kind != TransferKind.upload;
  }

  bool canResume(int id) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || cloudService is! CloudOperationPauseResume) return false;
    final entry = _entries[index];
    return entry.state == TransferState.paused &&
        entry.kind != TransferKind.upload;
  }

  Future<bool> pause(int id) async {
    if (!canPause(id)) return false;
    final service = cloudService as CloudOperationPauseResume;
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    final entry = _entries[index];
    try {
      final status = await service.operationPause(entry.operationId);
      if (status.operationId != entry.operationId ||
          status.kind != entry.kind.coreName ||
          status.state != 'paused') {
        return false;
      }
      final currentIndex = _entries.indexWhere((value) => value.id == id);
      if (currentIndex < 0) return false;
      final current = _entries[currentIndex];
      if (current.state != TransferState.running) return false;
      _entries[currentIndex] = current.copyWith(
        state: TransferState.paused,
        bytesTransferred: status.bytesTransferred,
        totalBytes: status.totalBytes > 0
            ? status.totalBytes
            : current.totalBytes,
        completedUnits: status.completedUnits,
        totalUnits: status.totalUnits,
      );
      _notify();
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> resume(int id) async {
    if (!canResume(id)) return false;
    final service = cloudService as CloudOperationPauseResume;
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    final entry = _entries[index];
    try {
      final status = await service.operationResume(entry.operationId);
      if (status.operationId != entry.operationId ||
          status.kind != entry.kind.coreName ||
          status.state != 'running') {
        return false;
      }
      final currentIndex = _entries.indexWhere((value) => value.id == id);
      if (currentIndex < 0) return false;
      final current = _entries[currentIndex];
      if (current.state != TransferState.paused) return false;
      _entries[currentIndex] = current.copyWith(
        state: TransferState.running,
        bytesTransferred: status.bytesTransferred,
        totalBytes: status.totalBytes > 0
            ? status.totalBytes
            : current.totalBytes,
        completedUnits: status.completedUnits,
        totalUnits: status.totalUnits,
      );
      _notify();
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> cancel(int id) async {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    final entry = _entries[index];
    if (entry.state == TransferState.queued) return cancelQueued(id);
    if (entry.state == TransferState.cancelling) {
      return _cancelDecisions[id]?.future ?? true;
    }
    if (entry.state != TransferState.running &&
        entry.state != TransferState.paused) {
      return false;
    }

    final decision = Completer<bool>();
    _cancelDecisions[id] = decision;
    _entries[index] = entry.copyWith(
      state: TransferState.cancelling,
      cancelRequested: true,
      errorMessage: null,
    );
    _notify();
    try {
      final status = await cloudService.operationCancel(entry.operationId);
      final accepted = _reconcileCancellation(entry, status);
      decision.complete(accepted);
      return accepted;
    } on CloudFailure catch (error) {
      // During icon preparation the operation is intentionally not registered
      // yet. A local cancellation remains authoritative and prevents upload.
      final accepted = error.code == 'operation_not_found';
      if (!accepted) _rollbackCancellation(id, entry.state);
      decision.complete(accepted);
      return accepted;
    } on Object {
      _rollbackCancellation(id, entry.state);
      decision.complete(false);
      return false;
    } finally {
      if (identical(_cancelDecisions[id], decision)) {
        _cancelDecisions.remove(id);
      }
    }
  }

  void clearFinished({TransferKind? kind}) {
    bool shouldRemove(TransferEntry entry) =>
        (kind == null || entry.kind == kind) &&
        entry.state != TransferState.running &&
        entry.state != TransferState.paused &&
        entry.state != TransferState.cancelling &&
        entry.state != TransferState.queued;

    final removedIds = _entries
        .where(shouldRemove)
        .map((entry) => entry.id)
        .toList(growable: false);
    _entries.removeWhere(shouldRemove);
    for (final id in removedIds) {
      _iconRetries.remove(id);
    }
    _notify();
  }

  Future<String?> _runUpload(
    int entryId,
    String operationId,
    String folderId,
    UploadRequest request,
    VoidCallback onFolderChanged,
  ) async {
    PreparedIcon? prepared;
    String? preparedPathForCleanup;
    String? warning;
    String? uploadedFileId;
    final iconSource = request.iconSourcePath ?? request.path;
    try {
      await _throwIfCancellationRequested(entryId);
      if (request.autoFileIcon) {
        _setStage(entryId, TransferStage.preparingIcon, message: '正在提取并压缩图标');
        try {
          prepared = await cloudService.prepareIcon(iconSource);
          preparedPathForCleanup = prepared.path;
          if (prepared.path.isEmpty || prepared.bytes >= 100000) {
            warning = '核心未能生成小于 100KB 的有效图标';
            prepared = null;
          }
        } on CloudFailure catch (error) {
          warning = '未能获取图标：${error.message}';
        } on Object {
          warning = '未能获取图标';
        }
      }

      // Icon extraction can be slow and is not itself a tracked core transfer.
      // Never start the upload if cancellation arrived during preparation.
      await _throwIfCancellationRequested(entryId);
      _setStage(
        entryId,
        TransferStage.transferring,
        message: _isApk(request.path) ? '正在上传 APK' : '正在上传文件',
      );

      final result = await cloudService.upload(
        folderId,
        request.path,
        compatibilityWrap: request.compatibilityWrap,
        kind: request.kind,
        operationId: operationId,
      );
      if (request.autoFileIcon) {
        try {
          uploadedFileId = _requireUploadedFileId(result);
        } on CloudFailure catch (error) {
          warning ??= '无法确认刚上传文件的身份：${error.message}';
        } on Object {
          warning ??= '无法确认刚上传文件的身份';
        }
      }
      if (prepared != null && uploadedFileId != null) {
        await _throwIfCancellationRequested(entryId);
        _setStage(
          entryId,
          TransferStage.bindingIcon,
          message: 'APK 已上传，正在绑定图标',
        );
        try {
          await cloudService.setIcon(uploadedFileId, prepared.path);
          warning = null;
        } on CloudFailure catch (error) {
          warning = '图标绑定失败：${error.message}';
        } on Object {
          warning = '图标绑定失败';
        }
      }
      if (warning != null) {
        final fileId = uploadedFileId;
        if (fileId != null) {
          _iconRetries[entryId] = _IconRetry(
            fileId: fileId,
            sourcePath: iconSource,
            onFolderChanged: onFolderChanged,
          );
        }
        return _partialIconWarning(
          request.path,
          warning,
          retryAvailable: fileId != null,
        );
      }
      _iconRetries.remove(entryId);
      return null;
    } finally {
      final preparedPath = preparedPathForCleanup;
      if (preparedPath != null && !_samePath(preparedPath, iconSource)) {
        try {
          final file = File(preparedPath);
          if (await file.exists()) await file.delete();
        } on Object {
          // Prepared icons are cache files; cleanup never changes the result.
        }
      }
    }
  }

  Future<String?> _runIconRetry(int entryId, _IconRetry retry) async {
    PreparedIcon? prepared;
    try {
      await _throwIfCancellationRequested(entryId);
      _setStage(entryId, TransferStage.preparingIcon, message: '正在重新提取并压缩图标');
      try {
        prepared = await cloudService.prepareIcon(retry.sourcePath);
        if (prepared.path.isEmpty || prepared.bytes >= 100000) {
          return _partialIconWarning(
            retry.sourcePath,
            '核心未能生成小于 100KB 的有效图标',
            retryAvailable: true,
          );
        }
        await _throwIfCancellationRequested(entryId);
        _setStage(entryId, TransferStage.bindingIcon, message: '正在重试图标绑定');
        await cloudService.setIcon(retry.fileId, prepared.path);
        _iconRetries.remove(entryId);
        return null;
      } on CloudFailure catch (error) {
        if (error.code == 'cancelled') rethrow;
        return _partialIconWarning(
          retry.sourcePath,
          '图标重试失败：${error.message}',
          retryAvailable: true,
        );
      } on Object {
        return _partialIconWarning(
          retry.sourcePath,
          '图标重试失败',
          retryAvailable: true,
        );
      }
    } finally {
      final preparedPath = prepared?.path;
      if (preparedPath != null && !_samePath(preparedPath, retry.sourcePath)) {
        try {
          final file = File(preparedPath);
          if (await file.exists()) await file.delete();
        } on Object {
          // Prepared icons are disposable cache files.
        }
      }
    }
  }

  String _requireUploadedFileId(UploadResult result) {
    final directId = result.id;
    if (directId != null && directId.isNotEmpty) return directId;
    throw const CloudFailure(
      'missing_uploaded_file_id',
      '核心未返回刚上传文件的 ID，已阻止按同名文件猜测并错误绑定',
    );
  }

  Future<void> _drain() async {
    if (_admitting || _disposed) return;
    _admitting = true;
    try {
      final capacity = await _resolveTransferCapacity();
      while (!_disposed && _queue.isNotEmpty && _activeJobs.length < capacity) {
        final job = _queue.removeFirst();
        final index = _entries.indexWhere((entry) => entry.id == job.id);
        if (index < 0 || _entries[index].state != TransferState.queued) {
          continue;
        }
        _entries[index] = _entries[index].copyWith(
          state: TransferState.running,
        );
        final poller = _OperationPoller(
          operationPollInterval,
          () => _pollOperation(job.id, job.operationId),
        )..start();
        _activeJobs[job.id] = job;
        _activePollers[job.id] = poller;
        _notify();
        unawaited(_runActiveJob(job, poller));
      }
    } finally {
      _admitting = false;
      final capacity = _transferCapacity;
      if (!_disposed &&
          capacity != null &&
          _queue.isNotEmpty &&
          _activeJobs.length < capacity) {
        scheduleMicrotask(_drain);
      }
    }
  }

  Future<int> _resolveTransferCapacity() {
    final cached = _transferCapacity;
    if (cached != null) return Future<int>.value(cached);
    final pending = _transferCapacityFuture;
    if (pending != null) return pending;

    final Future<int> future = () async {
      final service = cloudService;
      if (service is CloudRuntimeCapabilitiesProvider) {
        try {
          final provider = service as CloudRuntimeCapabilitiesProvider;
          final capabilities = await provider.runtimeCapabilities();
          return capabilities.transferWorkers;
        } on Object {
          // Fall through to the platform-reported device capacity. Both paths
          // are device adaptive; no fixed transfer width is introduced here.
        }
      }
      return Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 1;
    }();
    _transferCapacityFuture = future;
    return future.then<int>((capacity) {
      final normalized = capacity > 0 ? capacity : 1;
      _transferCapacity = normalized;
      _transferCapacityFuture = null;
      return normalized;
    });
  }

  Future<void> _runActiveJob(_TransferJob job, _OperationPoller poller) async {
    try {
      final warning = await job.run();
      final completedIndex = _entries.indexWhere((entry) => entry.id == job.id);
      if (completedIndex >= 0) {
        final completed = _entries[completedIndex];
        // A successful core response is authoritative even if cancellation or
        // pause raced with the final commit.
        _entries[completedIndex] = completed.copyWith(
          state: warning == null
              ? TransferState.succeeded
              : TransferState.succeededWithWarning,
          stage: TransferStage.finished,
          cancelRequested: false,
          errorMessage: warning,
          iconRetryAvailable:
              warning != null && _iconRetries.containsKey(job.id),
        );
      }
      if (!_disposed && completedIndex >= 0) {
        job.onSuccess();
      }
    } on _DirectoryUploadCancelled catch (cancelled) {
      _cancelled(
        job.id,
        message: cancelled.result.summary,
        directoryUploadResult: cancelled.result,
      );
      if (!_disposed && cancelled.result.hasRemoteChanges) {
        job.onSuccess();
      }
    } on CloudFailure catch (error) {
      if (error.code == 'cancelled') {
        _cancelled(job.id);
      } else {
        _fail(job.id, error.message);
      }
    } on Object {
      _fail(job.id, '传输失败，请稍后重试');
    } finally {
      await poller.stop();
      await _forgetOperation(job.operationId);
      if (identical(_activePollers[job.id], poller)) {
        _activePollers.remove(job.id);
      }
      if (identical(_activeJobs[job.id], job)) {
        _activeJobs.remove(job.id);
      }
      _notify();
      if (!_disposed) unawaited(_drain());
    }
  }

  @override
  void dispose() {
    final activeIds = _activeJobs.keys.toList(growable: false);
    for (final id in activeIds) {
      unawaited(cancel(id));
    }
    _disposed = true;
    for (final poller in _activePollers.values) {
      poller.cancel();
    }
    _activePollers.clear();
    _queue.clear();
    _iconRetries.clear();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _fail(int id, String message) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index >= 0) {
      _entries[index] = _entries[index].copyWith(
        state: TransferState.failed,
        stage: TransferStage.finished,
        cancelRequested: false,
        errorMessage: message,
        iconRetryAvailable: false,
      );
      _iconRetries.remove(id);
    }
  }

  void _cancelled(
    int id, {
    String? message,
    DirectoryUploadResult? directoryUploadResult,
  }) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index >= 0) {
      final retryAvailable = _iconRetries.containsKey(id);
      _entries[index] = _entries[index].copyWith(
        state: retryAvailable
            ? TransferState.succeededWithWarning
            : TransferState.cancelled,
        stage: TransferStage.finished,
        cancelRequested: !retryAvailable,
        errorMessage: retryAvailable ? 'APK 已上传；已取消图标绑定重试，可再次重试图标绑定' : message,
        iconRetryAvailable: retryAvailable,
        directoryUploadResult: directoryUploadResult,
      );
    }
  }

  void _setDirectoryUploadResult(int id, DirectoryUploadResult result) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(directoryUploadResult: result);
    _notify();
  }

  void _setStage(int id, TransferStage stage, {required String message}) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(
      stage: stage,
      errorMessage: message,
    );
    _notify();
  }

  Future<void> _pollOperation(int id, String operationId) async {
    try {
      final status = await cloudService.operationStatus(operationId);
      if (status.operationId != operationId) return;
      final index = _entries.indexWhere((entry) => entry.id == id);
      if (index < 0) return;
      final entry = _entries[index];
      if (status.kind != entry.kind.coreName) return;
      if (entry.state != TransferState.running &&
          entry.state != TransferState.paused &&
          entry.state != TransferState.cancelling) {
        return;
      }
      // Status polling is serialized, so the core snapshot is authoritative.
      // In particular, the Rust uploader resets bytesTransferred when an ACW
      // challenge starts a fresh attempt; retaining the old maximum would
      // leave the retry falsely displayed at 100%.
      final transferred = status.bytesTransferred;
      final total = status.totalBytes > 0
          ? status.totalBytes
          : entry.totalBytes;
      final coreCancelling =
          status.state == 'cancelling' || status.state == 'cancelled';
      final corePaused = status.state == 'paused';
      _entries[index] = entry.copyWith(
        state: coreCancelling
            ? TransferState.cancelling
            : corePaused
            ? TransferState.paused
            : status.state == 'running' && entry.state == TransferState.paused
            ? TransferState.running
            : entry.state,
        bytesTransferred: transferred,
        totalBytes: total,
        completedUnits: status.completedUnits,
        totalUnits: status.totalUnits,
        cancelRequested: coreCancelling ? true : entry.cancelRequested,
      );
      _notify();
      final updated = _entries[index];
      if (updated.cancelRequested && !_cancelDecisions.containsKey(id)) {
        if (status.state == 'running') {
          await _retryCancellation(updated);
        } else if (status.state == 'cancelling' ||
            status.state == 'cancelled' ||
            status.state == 'succeeded' ||
            status.state == 'failed') {
          _reconcileCancellation(updated, status);
        }
      }
    } on Object {
      // Status is advisory. The transfer result remains authoritative.
    }
  }

  Future<void> _forgetOperation(String operationId) async {
    try {
      await cloudService.operationForget(operationId);
    } on Object {
      // Forgetting only releases core bookkeeping and never changes the result.
    }
  }

  Future<void> _retryCancellation(TransferEntry entry) async {
    try {
      final status = await cloudService.operationCancel(entry.operationId);
      _reconcileCancellation(entry, status);
    } on Object {
      // The operation may still be crossing the FFI registration boundary.
      // Keep the local request and retry after the next successful status poll.
    }
  }

  Future<void> _throwIfCancellationRequested(int id) async {
    var index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || !_entries[index].cancelRequested) return;
    final pendingDecision = _cancelDecisions[id];
    if (pendingDecision != null && !await pendingDecision.future) return;
    index = _entries.indexWhere((entry) => entry.id == id);
    if (index >= 0 && _entries[index].cancelRequested) {
      throw const CloudFailure('cancelled', '传输已取消');
    }
  }

  bool _reconcileCancellation(
    TransferEntry requestedEntry,
    CloudOperationStatus status,
  ) {
    final sameOperation =
        status.operationId == requestedEntry.operationId &&
        status.kind == requestedEntry.kind.coreName;
    // operation_cancel atomically changes a running Rust operation to
    // cancelling before returning. A running or terminal response therefore
    // means cancellation was not accepted (or lost a completion race).
    final accepted =
        sameOperation &&
        (status.state == 'cancelling' || status.state == 'cancelled');
    final index = _entries.indexWhere((entry) => entry.id == requestedEntry.id);
    if (index >= 0) {
      final entry = _entries[index];
      if (entry.state == TransferState.running ||
          entry.state == TransferState.paused ||
          entry.state == TransferState.cancelling) {
        // A mismatched identity is not allowed to mutate another transfer's
        // progress. Cancellation replies may race a newer status poll, so
        // matching replies keep byte progress monotonic; retry resets come
        // from the serialized operation_status polling path above.
        final transferred = sameOperation
            ? (status.bytesTransferred > entry.bytesTransferred
                  ? status.bytesTransferred
                  : entry.bytesTransferred)
            : entry.bytesTransferred;
        final total = sameOperation && status.totalBytes > 0
            ? status.totalBytes
            : entry.totalBytes;
        _entries[index] = entry.copyWith(
          state: accepted
              ? TransferState.cancelling
              : requestedEntry.state == TransferState.paused
              ? TransferState.paused
              : TransferState.running,
          bytesTransferred: transferred,
          totalBytes: total,
          completedUnits: sameOperation
              ? status.completedUnits
              : entry.completedUnits,
          totalUnits: sameOperation ? status.totalUnits : entry.totalUnits,
          cancelRequested: accepted,
        );
        _notify();
      }
    }
    return accepted;
  }

  void _rollbackCancellation(int id, TransferState previousState) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    final entry = _entries[index];
    if (entry.state != TransferState.running &&
        entry.state != TransferState.paused &&
        entry.state != TransferState.cancelling) {
      return;
    }
    _entries[index] = entry.copyWith(
      state: previousState == TransferState.paused
          ? TransferState.paused
          : TransferState.running,
      cancelRequested: false,
    );
    _notify();
  }

  String _newOperationId(TransferKind kind, int sequence) {
    final value = _operationIdFactory(kind, sequence);
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'operationId', '必须是安全的 ASCII 标识');
    }
    return value;
  }
}

class _TransferJob {
  const _TransferJob(this.id, this.operationId, this.run, this.onSuccess);

  final int id;
  final String operationId;
  final Future<String?> Function() run;
  final VoidCallback onSuccess;
}

class _IconRetry {
  const _IconRetry({
    required this.fileId,
    required this.sourcePath,
    required this.onFolderChanged,
  });

  final String fileId;
  final String sourcePath;
  final VoidCallback onFolderChanged;
}

class _OperationPoller {
  _OperationPoller(this.interval, this.poll);

  final Duration interval;
  final Future<void> Function() poll;
  Timer? _timer;
  Future<void>? _pending;

  void start() {
    _timer = Timer.periodic(interval, (_) {
      if (_pending != null) return;
      _pending = poll().whenComplete(() => _pending = null);
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _pending;
  }

  void cancel() => _timer?.cancel();
}

String _defaultOperationId(TransferKind kind, int sequence) {
  final kindToken = switch (kind) {
    TransferKind.upload => 'u',
    TransferKind.directoryUpload => 'dir',
    TransferKind.download => 'd',
  };
  final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return 'lyu-$kindToken-$timestamp-${sequence.toRadixString(36)}';
}

class _DirectoryUploadCancelled {
  const _DirectoryUploadCancelled(this.result);

  final DirectoryUploadResult result;
}

String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;

bool _isApk(String path) => path.toLowerCase().endsWith('.apk');

String _partialIconWarning(
  String uploadedPath,
  String reason, {
  required bool retryAvailable,
}) {
  final uploadedKind = _isApk(uploadedPath) ? 'APK' : '文件';
  final action = retryAvailable
      ? '可重试图标绑定，不会再次上传 $uploadedKind'
      : '请刷新目录后在文件菜单选择“设置自定义图标”';
  return '$uploadedKind 已上传，但$reason；$action';
}

bool _samePath(String first, String second) {
  if (Platform.isWindows) return first.toLowerCase() == second.toLowerCase();
  return first == second;
}
