import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/models/transfer_entry.dart';
import 'package:lanzouyou/pages/transfers/transfers_page.dart';
import 'package:lanzouyou/services/cloud_service.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'active transfer shows byte progress and accessible cancellation state',
    (tester) async {
      final cloud = _PageSlowCloudService();
      final controller = TransferController(
        cloud,
        operationPollInterval: const Duration(milliseconds: 1),
        operationIdFactory: (kind, sequence) => 'page-${kind.name}-$sequence',
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: TransfersPage(controller: controller)),
      );
      controller.enqueueUploads(
        folderId: '-1',
        paths: const <String>['sample.apk'],
        onFolderChanged: () {},
      );
      await tester.pump();
      cloud
        ..bytesTransferred = 100
        ..totalBytes = 0;
      await _pumpUntil(
        tester,
        () => controller.entries.single.bytesTransferred == 100,
      );

      expect(find.text('已传输 100 B'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(find.byTooltip('取消上传'), findsOneWidget);
      expect(tester.getSize(find.byTooltip('取消上传')), const Size(48, 48));

      cloud
        ..bytesTransferred = 512
        ..totalBytes = 1024;
      await _pumpUntil(tester, () => controller.entries.single.progress == 0.5);
      expect(find.text('512 B / 1 KB（50%）'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );

      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '取消上传',
        ),
      );
      await tester.pump();
      expect(controller.entries.single.state, TransferState.cancelling);
      expect(find.text('正在取消'), findsOneWidget);
      expect(find.bySemanticsLabel('正在取消传输，请稍候'), findsOneWidget);
      expect(cloud.cancelledOperationIds, hasLength(1));

      cloud.completeCancelled();
      await _pumpUntil(
        tester,
        () => controller.entries.single.state == TransferState.cancelled,
      );
      expect(find.text('已取消'), findsOneWidget);
      expect(cloud.forgottenOperationIds, hasLength(1));
    },
  );

  testWidgets('partial icon success exposes a retry that never uploads again', (
    tester,
  ) async {
    final cloud = FakeCloudService()
      ..setIconFailure = const CloudFailure(
        'icon_bind_failed',
        '临时失败',
        retriable: true,
      );
    final controller = TransferController(cloud);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: TransfersPage(controller: controller)),
    );
    controller.enqueueUploadRequests(
      folderId: '-1',
      requests: const <UploadRequest>[
        UploadRequest(path: 'retry.apk', kind: 'file', autoFileIcon: true),
      ],
      onFolderChanged: () {},
    );
    await _pumpUntil(
      tester,
      () =>
          controller.entries.single.state == TransferState.succeededWithWarning,
    );

    expect(find.byTooltip('重试图标绑定'), findsOneWidget);
    expect(find.textContaining('不会再次上传 APK'), findsOneWidget);
    expect(cloud.uploads, hasLength(1));

    cloud.setIconFailure = null;
    await tester.tap(find.byTooltip('重试图标绑定'));
    await _pumpUntil(
      tester,
      () => controller.entries.single.state == TransferState.succeeded,
    );

    expect(find.text('传输成功'), findsOneWidget);
    expect(find.byTooltip('重试图标绑定'), findsNothing);
    expect(cloud.uploads, hasLength(1));
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 2));
    if (predicate()) return;
  }
  throw TimeoutException('widget condition was not reached');
}

class _PageSlowCloudService extends FakeCloudService {
  final Completer<UploadResult> _upload = Completer<UploadResult>();
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
  }) => _upload.future;

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

  void completeCancelled() {
    _upload.completeError(const CloudFailure('cancelled', '传输已取消'));
  }
}
