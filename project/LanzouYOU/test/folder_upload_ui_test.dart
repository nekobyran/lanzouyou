import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/models/directory_upload.dart';
import 'package:lanzouyou/pages/files/folder_upload/upload_options_dialog.dart';
import 'package:lanzouyou/pages/transfers/transfers_page.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('upload options keeps folder action usable at high text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    UploadOptionsChoice? selected;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                selected = await showDialog<UploadOptionsChoice>(
                  context: context,
                  builder: (_) => const UploadOptionsDialog(),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final folder = find.byKey(const Key('folder-upload-action'));
    await tester.ensureVisible(folder);
    await tester.tap(folder);
    await tester.pumpAndSettle();
    expect(selected?.kind, UploadPickerKind.directory);
  });

  testWidgets('partial directory transfer opens lazy failure details', (
    tester,
  ) async {
    final cloud = FakeCloudService()
      ..directoryUploadResult = DirectoryUploadResult.fromJson(
        <String, Object?>{
          'state': 'partial',
          'atomic': false,
          'partialRemoteRetained': true,
          'rootName': '软件合集',
          'remoteRootId': '10',
          'totalDirectories': 1,
          'createdDirectories': 1,
          'totalFiles': 2,
          'processedFiles': 2,
          'uploadedFiles': 1,
          'totalBytes': 20,
          'uploadedBytes': 10,
          'autoApkIcons': true,
          'iconBoundFiles': 1,
          'failures': <Map<String, Object?>>[
            <String, Object?>{
              'relativePath': '工具/失败.apk',
              'stage': 'upload_file',
              'code': 'remote_error',
              'message': '未能上传该文件',
              'retriable': true,
            },
          ],
        },
      );
    final controller = TransferController(cloud);
    controller.enqueueDirectoryUpload(
      folderId: '-1',
      request: const DirectoryUploadRequest(path: r'D:\软件合集'),
      onFolderChanged: () {},
    );
    await _waitForTransfer(controller);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: TransfersPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('不会自动回滚'), findsOneWidget);

    await tester.tap(find.text('软件合集'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('directory-upload-failure-list')),
      findsOneWidget,
    );
    expect(find.text('工具/失败.apk'), findsOneWidget);
    expect(find.text('未能上传该文件'), findsOneWidget);
  });
}

Future<void> _waitForTransfer(TransferController controller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (controller.hasRunning ||
      controller.entries.any((entry) => entry.state.name == 'queued')) {
    if (DateTime.now().isAfter(deadline)) fail('transfer did not finish');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
