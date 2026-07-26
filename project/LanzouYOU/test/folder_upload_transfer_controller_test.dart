import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/models/directory_upload.dart';
import 'package:lanzouyou/models/transfer_entry.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  test(
    'one directory becomes one tracked transfer and partial result stays visible',
    () async {
      final cloud = FakeCloudService()
        ..directoryUploadResult = _result(
          state: 'partial',
          uploadedFiles: 2,
          failures: <Map<String, Object?>>[_failure('nested/failed.apk')],
        );
      final controller = TransferController(
        cloud,
        operationIdFactory: _operationId,
      );
      var refreshes = 0;

      controller.enqueueDirectoryUpload(
        folderId: '-1',
        request: const DirectoryUploadRequest(
          path: r'D:\apps',
          compatibilityWrap: true,
          autoApkIcons: true,
        ),
        onFolderChanged: () => refreshes++,
      );
      await _waitForTransfers(controller);

      final entry = controller.entries.single;
      expect(entry.kind, TransferKind.directoryUpload);
      expect(entry.state, TransferState.succeededWithWarning);
      expect(entry.directoryUploadResult?.state, DirectoryUploadState.partial);
      expect(entry.errorMessage, contains('2/3'));
      expect(entry.errorMessage, contains('不会自动回滚'));
      expect(cloud.directoryUploads, hasLength(1));
      expect(cloud.directoryUploads.single['compatibilityWrap'], isTrue);
      expect(cloud.directoryUploads.single['autoApkIcons'], isTrue);
      expect(refreshes, 1);
    },
  );

  test(
    'directory cancellation stops as one core operation and preserves residual result',
    () async {
      final cloud = _SlowDirectoryCloud();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: _operationId,
      );
      var refreshes = 0;
      controller.enqueueDirectoryUpload(
        folderId: '20',
        request: const DirectoryUploadRequest(path: r'D:\large-library'),
        onFolderChanged: () => refreshes++,
      );
      await cloud.started.future;
      final entry = controller.entries.single;

      expect(await controller.cancel(entry.id), isTrue);
      expect(entry.operationId, 'test-directoryUpload-1');
      cloud.completeCancelled();
      await _waitForTransfers(controller);

      final cancelled = controller.entries.single;
      expect(cancelled.state, TransferState.cancelled);
      expect(cancelled.directoryUploadResult?.remoteRootId, '10');
      expect(cancelled.errorMessage, contains('不会继续开始新项目'));
      expect(cloud.cancelledOperationIds, <String>[entry.operationId]);
      expect(refreshes, 1);
    },
  );
}

class _SlowDirectoryCloud extends FakeCloudService {
  final Completer<void> started = Completer<void>();
  final Completer<DirectoryUploadResult> _result =
      Completer<DirectoryUploadResult>();
  final List<String> cancelledOperationIds = <String>[];

  @override
  Future<DirectoryUploadResult> uploadDirectory(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    bool autoApkIcons = false,
    String? operationId,
  }) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'directory_upload',
      state: 'running',
      completedUnits: 1,
      totalUnits: 3,
      bytesTransferred: 100,
      totalBytes: 300,
      itemsFound: 1,
    );
  }

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    cancelledOperationIds.add(operationId);
    return CloudOperationStatus(
      operationId: operationId,
      kind: 'directory_upload',
      state: 'cancelling',
      completedUnits: 1,
      totalUnits: 3,
      bytesTransferred: 100,
      totalBytes: 300,
      itemsFound: 1,
    );
  }

  void completeCancelled() {
    _result.complete(_resultValue('cancelled', uploadedFiles: 1));
  }
}

DirectoryUploadResult _result({
  required String state,
  required int uploadedFiles,
  required List<Map<String, Object?>> failures,
}) => _resultValue(state, uploadedFiles: uploadedFiles, failures: failures);

DirectoryUploadResult _resultValue(
  String state, {
  required int uploadedFiles,
  List<Map<String, Object?>> failures = const <Map<String, Object?>>[],
}) => DirectoryUploadResult.fromJson(<String, Object?>{
  'state': state,
  'atomic': false,
  'rootName': 'apps',
  'remoteRootId': '10',
  'partialRemoteRetained': true,
  'totalDirectories': 2,
  'createdDirectories': 2,
  'totalFiles': 3,
  'processedFiles': state == 'cancelled' ? 1 : 3,
  'uploadedFiles': uploadedFiles,
  'totalBytes': 300,
  'uploadedBytes': uploadedFiles * 100,
  'autoApkIcons': false,
  'iconBoundFiles': 0,
  'failures': failures,
});

Map<String, Object?> _failure(String path) => <String, Object?>{
  'relativePath': path,
  'stage': 'upload_file',
  'code': 'remote_error',
  'message': '上传失败',
  'retriable': true,
};

String _operationId(TransferKind kind, int sequence) =>
    'test-${kind.name}-$sequence';

Future<void> _waitForTransfers(TransferController controller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (controller.hasRunning ||
      controller.entries.any((entry) => entry.state == TransferState.queued)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('transfer did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
