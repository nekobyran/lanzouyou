import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/controllers/recycle_controller.dart';
import 'package:lanzouyou/models/cloud_item.dart';

import 'support/fakes.dart';

void main() {
  test(
    'recycle controller loads, selects, restores and empties items',
    () async {
      final cloud = FakeCloudService()
        ..recycleItems.addAll(const <CloudItem>[
          CloudItem(id: '1', name: '旧文件.zip', isFolder: false, isRecycle: true),
          CloudItem(id: '2', name: '旧目录', isFolder: true, isRecycle: true),
        ]);
      final expiredMessages = <String>[];
      final controller = RecycleController(
        cloudService: cloud,
        onSessionExpired: (message) async => expiredMessages.add(message),
      );

      await controller.load();
      expect(controller.status, RecycleStatus.content);
      controller.toggleSelection(controller.items.first);
      expect(controller.selectionMode, isTrue);

      expect(await controller.restore(controller.selectedItems), isNull);
      expect(controller.items, hasLength(1));
      expect(await controller.empty(), isNull);
      expect(controller.status, RecycleStatus.empty);
      expect(expiredMessages, isEmpty);
    },
  );
}
