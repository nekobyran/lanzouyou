import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/transfers/transfers_page.dart';
import 'package:lanzouyou/services/cloud_service.dart';
import 'package:lanzouyou/services/rust_cloud_service.dart';
import 'package:lanzouyou/shared/app_theme.dart';

void main() {
  runApp(const _TransfersPreviewApp());
}

class _TransfersPreviewApp extends StatefulWidget {
  const _TransfersPreviewApp();

  @override
  State<_TransfersPreviewApp> createState() => _TransfersPreviewAppState();
}

class _TransfersPreviewAppState extends State<_TransfersPreviewApp> {
  late final TransferController _uploadController;
  late final TransferController _downloadController;

  @override
  void initState() {
    super.initState();
    _uploadController =
        TransferController(
          _PreviewTransferService('upload'),
          operationPollInterval: const Duration(milliseconds: 200),
        )..enqueueUploads(
          folderId: '-1',
          paths: const <String>['LanzouYOU-preview-upload.apk'],
          onFolderChanged: () {},
        );
    _downloadController =
        TransferController(
          _PreviewTransferService('download'),
          operationPollInterval: const Duration(milliseconds: 200),
        )..enqueueDownload(
          item: const CloudItem(
            id: 'preview-download',
            name: 'LanzouYOU-preview-download.zip',
            isFolder: false,
          ),
          destination: 'LanzouYOU-preview-download.zip',
        );
  }

  @override
  void dispose() {
    _uploadController.dispose();
    _downloadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LanzouYOU 传输进度验收',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: LayoutBuilder(
        builder: (context, constraints) {
          final panels = <Widget>[
            Expanded(child: TransfersPage(controller: _uploadController)),
            Expanded(child: TransfersPage(controller: _downloadController)),
          ];
          return constraints.maxWidth >= 900
              ? Row(children: panels)
              : Column(children: panels);
        },
      ),
    );
  }
}

class _PreviewTransferService extends RustCloudService {
  _PreviewTransferService(this.kind);

  final String kind;
  final Completer<UploadResult> _upload = Completer<UploadResult>();
  final Completer<void> _download = Completer<void>();
  var _pollCount = 0;
  var _cancelling = false;

  @override
  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  }) => _upload.future;

  @override
  Future<void> download(
    CloudItem item,
    String destination, {
    String? operationId,
  }) => _download.future;

  @override
  Future<CloudOperationStatus> operationStatus(String operationId) async {
    _pollCount++;
    const totalBytes = 64 * 1024 * 1024;
    final step = kind == 'upload' ? 512 * 1024 : 768 * 1024;
    final transferred = (_pollCount * step).clamp(0, totalBytes - 1);
    return CloudOperationStatus(
      operationId: operationId,
      kind: kind,
      state: _cancelling ? 'cancelling' : 'running',
      completedUnits: 0,
      totalUnits: 1,
      bytesTransferred: transferred,
      totalBytes: totalBytes,
      itemsFound: 0,
    );
  }

  @override
  Future<CloudOperationStatus> operationCancel(String operationId) async {
    _cancelling = true;
    return operationStatus(operationId);
  }

  @override
  Future<void> operationForget(String operationId) async {}
}
