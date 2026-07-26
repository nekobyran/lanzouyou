import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/transfer_controller.dart';
import 'package:lanzouyou/pages/files/folder_upload/folder_upload_launcher.dart';

import 'support/fakes.dart';

void main() {
  test('accessible folder is enqueued as one directory operation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'folder-upload-launcher-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final cloud = FakeCloudService();
    final controller = TransferController(cloud);

    final result = await FolderUploadLauncher.pickAndEnqueue(
      transferController: controller,
      cloudFolderId: '20',
      compatibilityWrap: true,
      autoApkIcons: true,
      onFolderChanged: () {},
      picker: () async => temp.path,
    );

    expect(result.enqueued, isTrue);
    expect(controller.entries, hasLength(1));
    await _waitUntil(() => cloud.directoryUploads.isNotEmpty);
    expect(cloud.directoryUploads.single['path'], temp.path);
    expect(cloud.directoryUploads.single['autoApkIcons'], isTrue);
  });

  test(
    'protected root and picker platform failure are rejected before core',
    () async {
      final cloud = FakeCloudService();
      final controller = TransferController(cloud);

      final root = await FolderUploadLauncher.pickAndEnqueue(
        transferController: controller,
        cloudFolderId: '-1',
        compatibilityWrap: false,
        autoApkIcons: false,
        onFolderChanged: () {},
        picker: () async => Platform.isWindows ? r'C:\' : '/',
      );
      expect(root.enqueued, isFalse);
      expect(root.message, contains('系统保护'));

      final denied = await FolderUploadLauncher.pickAndEnqueue(
        transferController: controller,
        cloudFolderId: '-1',
        compatibilityWrap: false,
        autoApkIcons: false,
        onFolderChanged: () {},
        picker: () => throw PlatformException(code: 'access_denied'),
      );
      expect(denied.enqueued, isFalse);
      expect(denied.message, contains('系统保护'));
      expect(cloud.directoryUploads, isEmpty);
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
