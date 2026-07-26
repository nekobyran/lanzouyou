import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/models/transfer_entry.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  test(
    'automatic icon upload binds the prepared image to the uploaded file',
    () async {
      final cloud = FakeCloudService();
      final controller = TransferController(cloud);
      var refreshCount = 0;

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(
            path: 'sample.apk',
            kind: 'file',
            autoFileIcon: true,
            iconSourcePath: 'sample.apk',
          ),
        ],
        onFolderChanged: () => refreshCount++,
      );
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.succeeded);
      expect(cloud.calls, contains('prepare_icon:sample.apk'));
      expect(
        cloud.calls.where((call) => call.startsWith('set_icon:1000:')),
        hasLength(1),
      );
      expect(refreshCount, 1);
    },
  );

  test(
    'automatic APK icon stages are visible and binding can retry without reupload',
    () async {
      final cloud = FakeCloudService()
        ..setIconFailure = const CloudFailure(
          'icon_bind_failed',
          '蓝奏云拒绝了图标',
          retriable: true,
        );
      final controller = TransferController(cloud);

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(
            path: 'one-click.apk',
            kind: 'file',
            autoFileIcon: true,
          ),
        ],
        onFolderChanged: () {},
      );
      await _waitForTransfers(controller);

      var entry = controller.entries.single;
      expect(entry.stage, TransferStage.finished);
      expect(entry.state, TransferState.succeededWithWarning);
      expect(entry.iconRetryAvailable, isTrue);
      expect(entry.errorMessage, contains('APK 已上传'));
      expect(entry.errorMessage, contains('重试图标绑定'));
      expect(cloud.uploads, hasLength(1));

      cloud.setIconFailure = null;
      expect(controller.retryIconBinding(entry.id), isTrue);
      await _waitForTransfers(controller);

      entry = controller.entries.single;
      expect(entry.state, TransferState.succeeded);
      expect(entry.stage, TransferStage.finished);
      expect(entry.iconRetryAvailable, isFalse);
      expect(cloud.uploads, hasLength(1));
      expect(
        cloud.calls.where((call) => call.startsWith('set_icon:1000:')),
        hasLength(2),
      );
    },
  );

  test(
    'icon preparation and APK upload expose real intermediate stages',
    () async {
      final cloud = _SlowCloudService(delayIconPreparation: true);
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
      );

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(path: 'staged.apk', kind: 'file', autoFileIcon: true),
        ],
        onFolderChanged: () {},
      );
      await cloud.iconPreparationStarted.future;
      expect(controller.entries.single.stage, TransferStage.preparingIcon);
      expect(controller.entries.single.errorMessage, '正在提取并压缩图标');

      cloud.completeIconPreparation('staged.apk');
      await cloud.uploadStarted.future;
      expect(controller.entries.single.stage, TransferStage.transferring);
      expect(controller.entries.single.errorMessage, '正在上传 APK');

      cloud.completeUpload();
      await _waitForTransfers(controller);
      expect(controller.entries.single.stage, TransferStage.finished);
      expect(controller.entries.single.errorMessage, isNull);
    },
  );

  test(
    'icon extraction failure does not upload an independent icon file',
    () async {
      final cloud = FakeCloudService()
        ..prepareIconFailure = const CloudFailure('unsupported_icon', '无法提取图标');
      final controller = TransferController(cloud);

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(path: 'archive.zip', kind: 'file', autoFileIcon: true),
        ],
        onFolderChanged: () {},
      );
      await _waitForTransfers(controller);

      expect(
        controller.entries.single.state,
        TransferState.succeededWithWarning,
      );
      expect(cloud.uploads, hasLength(1));
      expect(cloud.uploads.single['kind'], 'file');
      expect(
        cloud.calls.where((call) => call.startsWith('set_icon:')),
        isEmpty,
      );
    },
  );

  test(
    'missing upload id never guesses a same-name file for icon binding',
    () async {
      final cloud = FakeCloudService()
        ..omitUploadId = true
        ..folders['-1'] = const <CloudItem>[
          CloudItem(id: 'older-same-name', name: 'same.apk', isFolder: false),
        ];
      final controller = TransferController(cloud);

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(path: 'same.apk', kind: 'file', autoFileIcon: true),
        ],
        onFolderChanged: () {},
      );
      await _waitForTransfers(controller);

      final entry = controller.entries.single;
      expect(entry.state, TransferState.succeededWithWarning);
      expect(entry.iconRetryAvailable, isFalse);
      expect(entry.errorMessage, contains('已阻止按同名文件猜测'));
      expect(
        cloud.calls.where((call) => call.startsWith('set_icon:')),
        isEmpty,
      );
      expect(cloud.calls.where((call) => call.startsWith('list:')), isEmpty);
    },
  );

  test(
    'running transfer reports byte progress and always forgets success',
    () async {
      final cloud = _SlowCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
      );

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(path: r'C:\private\account-password\sample.apk'),
        ],
        onFolderChanged: () {},
      );
      await cloud.uploadStarted.future;
      final operationId = controller.entries.single.operationId;
      cloud
        ..bytesTransferred = 512
        ..totalBytes = 1024;

      await _waitUntil(() => controller.entries.single.bytesTransferred == 512);
      expect(controller.entries.single.state, TransferState.running);
      expect(controller.entries.single.progress, 0.5);
      expect(operationId, matches(RegExp(r'^[A-Za-z0-9._-]{1,64}$')));
      expect(operationId, isNot(contains('private')));
      expect(operationId, isNot(contains('password')));
      expect(cloud.uploadOperationIds.single, operationId);

      cloud.completeUpload();
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.succeeded);
      expect(cloud.forgottenOperationIds, contains(operationId));
    },
  );

  test(
    'upload progress follows a core retry reset instead of staying at 100%',
    () async {
      final cloud = _SlowCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      controller.enqueueUploads(
        folderId: '-1',
        paths: const <String>['retry-after-challenge.apk'],
        onFolderChanged: () {},
      );
      await cloud.uploadStarted.future;

      cloud
        ..bytesTransferred = 1024
        ..totalBytes = 1024;
      await _waitUntil(() => controller.entries.single.progress == 1);

      // Rust resets bytesTransferred when an ACW challenge starts another
      // upload attempt. The next serialized status snapshot must be visible.
      cloud.bytesTransferred = 128;
      await _waitUntil(() => controller.entries.single.bytesTransferred == 128);
      expect(controller.entries.single.progress, 0.125);

      cloud.completeUpload();
      await _waitForTransfers(controller);
      expect(controller.entries.single.state, TransferState.succeeded);
    },
  );

  test(
    'running cancellation calls core and stays cancelling until stopped',
    () async {
      final cloud = _SlowCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      var refreshCount = 0;

      controller.enqueueUploads(
        folderId: '-1',
        paths: const <String>['cancel-me.apk'],
        onFolderChanged: () => refreshCount++,
      );
      await cloud.uploadStarted.future;
      final entry = controller.entries.single;

      expect(await controller.cancel(entry.id), isTrue);
      expect(controller.entries.single.state, TransferState.cancelling);
      expect(controller.entries.single.cancelRequested, isTrue);
      expect(cloud.cancelledOperationIds, <String>[entry.operationId]);

      cloud.completeCancelled();
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.cancelled);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
      expect(refreshCount, 0);
    },
  );

  test(
    'accepted upload cancellation that arrives too late preserves success',
    () async {
      final cloud = _SlowCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      var refreshCount = 0;
      controller.enqueueUploads(
        folderId: '-1',
        paths: const <String>['late-upload-cancel.apk'],
        onFolderChanged: () => refreshCount++,
      );
      await cloud.uploadStarted.future;
      final entry = controller.entries.single;

      expect(await controller.cancel(entry.id), isTrue);
      expect(controller.entries.single.state, TransferState.cancelling);
      cloud.completeUpload();
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.succeeded);
      expect(controller.entries.single.cancelRequested, isFalse);
      expect(refreshCount, 1);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
    },
  );

  test(
    'authoritative succeeded cancel response prevents false cancellation',
    () async {
      final cloud = _SucceededBeforeCancelCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      var refreshCount = 0;
      controller.enqueueUploads(
        folderId: '-1',
        paths: const <String>['already-finished.apk'],
        onFolderChanged: () => refreshCount++,
      );
      await cloud.uploadStarted.future;
      final entry = controller.entries.single;

      final cancelFuture = controller.cancel(entry.id);
      await cloud.cancelCalled.future;
      cloud.completeUpload();
      await Future<void>.delayed(Duration.zero);
      expect(controller.entries.single.state, TransferState.succeeded);

      cloud.completeCancelAsSucceeded(entry.operationId);
      expect(await cancelFuture, isFalse);
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.succeeded);
      expect(controller.entries.single.cancelRequested, isFalse);
      expect(refreshCount, 1);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
    },
  );

  test(
    'operation_cancel strictly rejects running identity mismatches and terminals',
    () async {
      final cases = <({String label, String state, String? id, String kind})>[
        (label: 'running', state: 'running', id: null, kind: 'upload'),
        (
          label: 'wrong operationId',
          state: 'cancelling',
          id: 'different-operation',
          kind: 'upload',
        ),
        (label: 'wrong kind', state: 'cancelling', id: null, kind: 'download'),
        (label: 'failed terminal', state: 'failed', id: null, kind: 'upload'),
      ];

      for (final testCase in cases) {
        final cloud = _FixedCancelResponseCloudService(
          responseState: testCase.state,
          responseOperationId: testCase.id,
          responseKind: testCase.kind,
        );
        final controller = TransferController(
          cloud,
          operationPollInterval: const Duration(milliseconds: 1),
          operationIdFactory: _testOperationId,
        );
        controller.enqueueUploads(
          folderId: '-1',
          paths: <String>['strict-${testCase.label}.apk'],
          onFolderChanged: () {},
        );
        await cloud.uploadStarted.future;
        final entry = controller.entries.single;

        expect(
          await controller.cancel(entry.id),
          isFalse,
          reason: testCase.label,
        );
        expect(
          controller.entries.single.state,
          TransferState.running,
          reason: testCase.label,
        );
        expect(
          controller.entries.single.cancelRequested,
          isFalse,
          reason: testCase.label,
        );

        cloud.completeUpload();
        await _waitForTransfers(controller);
        expect(
          controller.entries.single.state,
          TransferState.succeeded,
          reason: testCase.label,
        );
      }
    },
  );

  test(
    'cancel retries after preregistration not-found reaches running core',
    () async {
      final cloud = _PreregistrationRaceCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      controller.enqueueUploads(
        folderId: '-1',
        paths: const <String>['registration-race.apk'],
        onFolderChanged: () {},
      );
      await cloud.uploadStarted.future;
      final entry = controller.entries.single;

      expect(await controller.cancel(entry.id), isTrue);
      expect(cloud.cancelCallCount, 1);
      expect(controller.entries.single.state, TransferState.cancelling);

      await _waitUntil(() => cloud.cancelCallCount >= 2);
      await _waitForTransfers(controller);
      expect(controller.entries.single.state, TransferState.cancelled);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
    },
  );

  test('queued cancellation never starts the queued transfer', () async {
    final cloud = _SlowCloudService();
    final controller = TransferController(
      cloud,
      operationPollInterval: const Duration(milliseconds: 1),
      operationIdFactory: _testOperationId,
    );

    controller.enqueueUploads(
      folderId: '-1',
      paths: const <String>['running.apk', 'queued.apk'],
      onFolderChanged: () {},
    );
    await cloud.uploadStarted.future;
    final queued = controller.entries.singleWhere(
      (entry) => entry.name == 'queued.apk',
    );

    expect(await controller.cancel(queued.id), isTrue);
    expect(
      controller.entries.singleWhere((entry) => entry.id == queued.id).state,
      TransferState.cancelled,
    );
    await _waitUntil(
      () => cloud.forgottenOperationIds.contains(queued.operationId),
    );
    expect(cloud.uploadOperationIds, isNot(contains(queued.operationId)));

    cloud.completeUpload();
    await _waitForTransfers(controller);
    expect(cloud.uploadOperationIds, hasLength(1));
  });

  test(
    'cancelling icon preparation prevents the upload from starting',
    () async {
      final cloud = _SlowCloudService(delayIconPreparation: true);
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );

      controller.enqueueUploadRequests(
        folderId: '-1',
        requests: const <UploadRequest>[
          UploadRequest(path: 'preparing.apk', autoFileIcon: true),
        ],
        onFolderChanged: () {},
      );
      await cloud.iconPreparationStarted.future;
      final entry = controller.entries.single;

      expect(await controller.cancel(entry.id), isTrue);
      expect(controller.entries.single.state, TransferState.cancelling);
      cloud.completeIconPreparation('preparing.apk');
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.cancelled);
      expect(cloud.uploadOperationIds, isEmpty);
      expect(cloud.cancelledOperationIds, <String>[entry.operationId]);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
    },
  );

  test('operation status parses the complete non-null core contract', () {
    final status = CloudOperationStatus.fromJson(const <String, Object?>{
      'operationId': 'safe-operation-1',
      'kind': 'download',
      'state': 'running',
      'completedUnits': 1,
      'totalUnits': 2,
      'bytesTransferred': 1024,
      'totalBytes': 2048,
      'itemsFound': 0,
    });

    expect(status.operationId, 'safe-operation-1');
    expect(status.totalUnits, 2);
    expect(status.totalBytes, 2048);
  });

  test(
    'download receives a safe operation id and supports cancellation',
    () async {
      final cloud = _SlowDownloadCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      controller.enqueueDownload(
        item: const CloudItem(
          id: 'download-file-id',
          name: 'download.apk',
          isFolder: false,
        ),
        destination: r'C:\private\credential\download.apk',
      );
      await cloud.downloadStarted.future;
      final entry = controller.entries.single;

      expect(cloud.downloadOperationIds, <String>[entry.operationId]);
      expect(entry.operationId, isNot(contains('private')));
      expect(entry.operationId, isNot(contains('credential')));
      expect(await controller.cancel(entry.id), isTrue);
      expect(controller.entries.single.state, TransferState.cancelling);
      cloud.completeCancelled();
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.cancelled);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
    },
  );

  test(
    'accepted download cancellation that arrives too late preserves success',
    () async {
      final cloud = _SlowDownloadCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _testOperationId,
      );
      controller.enqueueDownload(
        item: const CloudItem(
          id: 'late-download-file-id',
          name: 'late-download.apk',
          isFolder: false,
        ),
        destination: r'C:\safe\late-download.apk',
      );
      await cloud.downloadStarted.future;
      final entry = controller.entries.single;

      expect(await controller.cancel(entry.id), isTrue);
      expect(controller.entries.single.state, TransferState.cancelling);
      cloud.completeDownload();
      await _waitForTransfers(controller);

      expect(controller.entries.single.state, TransferState.succeeded);
      expect(controller.entries.single.cancelRequested, isFalse);
      expect(cloud.forgottenOperationIds, contains(entry.operationId));
    },
  );

  test('disposing best-effort cancels the active core operation', () async {
    final cloud = _SlowCloudService();
    final controller = TransferController(
      cloud,
      operationPollInterval: const Duration(milliseconds: 1),
      operationIdFactory: _testOperationId,
    );
    controller.enqueueUploads(
      folderId: '-1',
      paths: const <String>['dispose-active.apk'],
      onFolderChanged: () {},
    );
    await cloud.uploadStarted.future;
    final operationId = controller.entries.single.operationId;

    controller.dispose();
    await _waitUntil(() => cloud.cancelledOperationIds.contains(operationId));
    cloud.completeCancelled();
    await _waitUntil(() => cloud.forgottenOperationIds.contains(operationId));
  });
}

Future<void> _waitForTransfers(TransferController controller) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (controller.entries.every(
      (entry) =>
          entry.state != TransferState.queued &&
          entry.state != TransferState.running &&
          entry.state != TransferState.cancelling,
    )) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  throw TimeoutException('test transfer queue did not finish');
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw TimeoutException('condition was not reached');
}

String _testOperationId(TransferKind kind, int sequence) =>
    'test-${kind.name}-$sequence';

class _SlowCloudService extends FakeCloudService {
  _SlowCloudService({this.delayIconPreparation = false});

  final bool delayIconPreparation;
  final Completer<void> uploadStarted = Completer<void>();
  final Completer<void> iconPreparationStarted = Completer<void>();
  final Completer<UploadResult> _upload = Completer<UploadResult>();
  final Completer<PreparedIcon> _icon = Completer<PreparedIcon>();
  final List<String> uploadOperationIds = <String>[];
  final List<String> cancelledOperationIds = <String>[];
  final List<String> forgottenOperationIds = <String>[];
  int bytesTransferred = 0;
  int totalBytes = 0;

  @override
  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  }) {
    uploadOperationIds.add(operationId!);
    if (!uploadStarted.isCompleted) uploadStarted.complete();
    return _upload.future;
  }

  @override
  Future<PreparedIcon> prepareIcon(
    String sourcePath, {
    String? outputPath,
  }) async {
    if (!delayIconPreparation) {
      return super.prepareIcon(sourcePath, outputPath: outputPath);
    }
    if (!iconPreparationStarted.isCompleted) iconPreparationStarted.complete();
    return _icon.future;
  }

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'upload',
      state: cancelledOperationIds.contains(operationId)
          ? 'cancelling'
          : 'running',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      itemsFound: 0,
    );
  }

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    cancelledOperationIds.add(operationId);
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'upload',
      state: 'cancelling',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      itemsFound: 0,
    );
  }

  @override
  Future<void> operationForget(String operationId) async {
    forgottenOperationIds.add(operationId);
  }

  void completeUpload() {
    _upload.complete(
      const UploadResult(
        id: 'uploaded-id',
        folderId: '-1',
        originalName: 'sample.apk',
        uploadedName: 'sample.apk',
      ),
    );
  }

  void completeCancelled() {
    _upload.completeError(const CloudFailure('cancelled', '传输已取消'));
  }

  void completeIconPreparation(String sourcePath) {
    _icon.complete(
      PreparedIcon(
        path: sourcePath,
        mediaType: 'image/png',
        bytes: 50000,
        width: 128,
        height: 128,
        sourceKind: 'image',
      ),
    );
  }
}

class _SlowDownloadCloudService extends FakeCloudService {
  final Completer<void> downloadStarted = Completer<void>();
  final Completer<void> _download = Completer<void>();
  final List<String> downloadOperationIds = <String>[];
  final List<String> cancelledOperationIds = <String>[];
  final List<String> forgottenOperationIds = <String>[];

  @override
  Future<void> download(
    CloudItem item,
    String destination, {
    String? operationId,
  }) {
    downloadOperationIds.add(operationId!);
    downloadStarted.complete();
    return _download.future;
  }

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'download',
      state: cancelledOperationIds.contains(operationId)
          ? 'cancelling'
          : 'running',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: 0,
      totalBytes: 0,
      itemsFound: 0,
    );
  }

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    cancelledOperationIds.add(operationId);
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'download',
      state: 'cancelling',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: 0,
      totalBytes: 0,
      itemsFound: 0,
    );
  }

  @override
  Future<void> operationForget(String operationId) async {
    forgottenOperationIds.add(operationId);
  }

  void completeCancelled() {
    _download.completeError(const CloudFailure('cancelled', '传输已取消'));
  }

  void completeDownload() => _download.complete();
}

class _SucceededBeforeCancelCloudService extends _SlowCloudService {
  final Completer<void> cancelCalled = Completer<void>();
  final Completer<CloudOperationStatus> _cancelStatus =
      Completer<CloudOperationStatus>();

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) {
    cancelledOperationIds.add(operationId);
    cancelCalled.complete();
    return _cancelStatus.future;
  }

  void completeCancelAsSucceeded(String operationId) {
    _cancelStatus.complete(
      CloudOperationStatus(
        operationId: operationId,
        kind: 'upload',
        state: 'succeeded',
        completedUnits: 1,
        totalUnits: 1,
        bytesTransferred: 1024,
        totalBytes: 1024,
        itemsFound: 0,
      ),
    );
  }
}

class _PreregistrationRaceCloudService extends _SlowCloudService {
  var cancelCallCount = 0;

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    cancelCallCount++;
    cancelledOperationIds.add(operationId);
    if (cancelCallCount == 1) {
      throw const CloudFailure('operation_not_found', '未找到指定操作');
    }
    scheduleMicrotask(completeCancelled);
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'upload',
      state: 'cancelling',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      itemsFound: 0,
    );
  }

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'upload',
      state: 'running',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
      itemsFound: 0,
    );
  }
}

class _FixedCancelResponseCloudService extends _SlowCloudService {
  _FixedCancelResponseCloudService({
    required this.responseState,
    required this.responseKind,
    this.responseOperationId,
  });

  final String responseState;
  final String responseKind;
  final String? responseOperationId;

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    return CloudOperationStatus(
      operationId: responseOperationId ?? operationId,
      kind: responseKind,
      state: responseState,
      completedUnits: responseState == 'failed' ? 1 : 0,
      totalUnits: 1,
      bytesTransferred: 256,
      totalBytes: 1024,
      itemsFound: 0,
    );
  }
}
