import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/services/cloud_service.dart';

void main() {
  test('CloudItem parses the Rust camelCase schema', () {
    final item = CloudItem.fromJson(<String, Object?>{
      'id': 42,
      'name': '示例文件.zip',
      'isFolder': false,
      'size': 1024,
      'modifiedAt': '2026-07-13',
      'description': '说明',
      'hasPassword': true,
      'downloads': 7,
      'path': '/示例文件.zip',
      'hasCustomIcon': true,
      'iconUrl': 'https://example.invalid/icon/42',
      'isRecycle': true,
    });

    expect(item.id, '42');
    expect(item.size, '1024');
    expect(item.hasPassword, isTrue);
    expect(item.downloads, 7);
    expect(item.hasCustomIcon, isTrue);
    expect(item.iconUrl, contains('/42'));
    expect(item.isRecycle, isTrue);
  });

  test('ShareInfo accepts a missing direct URL for folders', () {
    final info = ShareInfo.fromJson(<String, Object?>{
      'id': '1',
      'isFolder': true,
      'name': '资料',
      'shareUrl': 'https://example.invalid/s/1',
      'password': '',
      'description': '',
      'directUrl': null,
    });

    expect(info.isFolder, isTrue);
    expect(info.directUrl, isNull);
  });

  test('ManagedDescription preserves a real empty description field', () {
    final description = ManagedDescription.fromJson(<String, Object?>{
      'id': '8',
      'isFolder': false,
      'name': '应用.apk',
      'description': '',
    });

    expect(description.description, isEmpty);
    expect(
      () => ManagedDescription.fromJson(<String, Object?>{
        'id': '8',
        'isFolder': false,
        'name': '应用.apk',
      }),
      throwsFormatException,
    );
  });

  test('AccountCapabilities accepts only official HTTPS portal URLs', () {
    Map<String, Object?> response(String portal) => <String, Object?>{
      'authenticated': true,
      'userId': '1',
      'accountPortalUrl': portal,
      'accountFeatures': <String>['云存储统计', '存储空间'],
      'membership': <String, Object?>{
        'state': 'available',
        'portalUrl':
            'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        'reason': '由官方页面完成开通',
        'features': <String>['包月', '包年'],
      },
      'personalization': <String, Object?>{
        'state': 'available',
        'portalUrl':
            'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan',
        'readable': false,
        'writable': false,
        'reason': '由官方页面配置',
        'features': <String>['下载页模板', '发布者昵称'],
      },
      'acceptsPaymentData': false,
    };

    final capabilities = AccountCapabilities.fromJson(
      response('https://pc.woozooo.com/account.php'),
    );
    expect(capabilities.membership.available, isTrue);
    expect(capabilities.membership.features, contains('包年'));
    expect(capabilities.personalization.portalUrl, isNotNull);
    expect(capabilities.accountFeatures, contains('云存储统计'));
    expect(capabilities.acceptsPaymentData, isFalse);
    expect(
      () => AccountCapabilities.fromJson(response('https://evil.example/pay')),
      throwsFormatException,
    );
  });

  test(
    'ReplaceFileResult requires confirmed preservation and deletion fields',
    () {
      final result = ReplaceFileResult.fromJson(<String, Object?>{
        'replaced': true,
        'oldFileId': 'old',
        'newFileId': 'new',
        'folderId': '-1',
        'finalName': '应用.apk',
        'uploadedName': 'upload.apk',
        'descriptionPreserved': true,
        'iconApplied': true,
        'oldDeleted': true,
        'cleanupRequired': false,
      });

      expect(result.newFileId, 'new');
      expect(result.descriptionPreserved, isTrue);
      expect(result.oldDeleted, isTrue);
    },
  );

  test('CloudOperationStatus recognizes replace_file as a separate kind', () {
    final status = CloudOperationStatus.fromJson(<String, Object?>{
      'operationId': 'replace-1',
      'kind': 'replace_file',
      'state': 'running',
      'completedUnits': 1,
      'totalUnits': 3,
      'bytesTransferred': 10,
      'totalBytes': 100,
      'itemsFound': 0,
    });

    expect(status.kind, 'replace_file');
  });
}
