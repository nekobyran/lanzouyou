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

  for (final state in MembershipState.values) {
    test('AccountCapabilities parses ${state.name} membership state', () {
      final capabilities = AccountCapabilities.fromJson(
        _accountResponse(state.name),
      );

      expect(capabilities.membershipProfile.state, state);
      expect(capabilities.membershipProfile.displayName, isNotEmpty);
      expect(
        capabilities.membershipProfile.expiresAt,
        state == MembershipState.vip ? DateTime(2027, 7, 30) : isNull,
      );
      expect(capabilities.entries, hasLength(9));
      expect(capabilities.facts, hasLength(8));
      expect(capabilities.plans, hasLength(7));
      expect(capabilities.personalization, hasLength(11));
      expect(capabilities.acceptsPaymentData, isFalse);
    });
  }

  test('AccountCapabilities rejects invalid membership enum', () {
    expect(
      () => AccountCapabilities.fromJson(_accountResponse('premium')),
      throwsFormatException,
    );
  });

  test('AccountCapabilities accepts only exact official portal routes', () {
    final evilHost = _accountResponse('vip')
      ..['accountPortalUrl'] =
          'https://evil.example/mydisk.php?item=profile&action=mypower';
    final wrongFieldRoute = _accountResponse('vip')
      ..['membershipPortalUrl'] =
          'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower';
    final dynamicPaymentToken = _accountResponse('vip')
      ..['membershipPortalUrl'] =
          'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan&token=secret';
    final mismatchedEntry = _accountResponse('vip');
    (mismatchedEntry['entries']! as List<Object?>)[1] = <String, Object?>{
      ...(mismatchedEntry['entries']! as List<Object?>)[1]!
          as Map<String, Object?>,
      'portalUrl':
          'https://pc.woozooo.com/mydisk.php?item=profile&action=orders',
    };

    for (final response in <Map<String, Object?>>[
      evilHost,
      wrongFieldRoute,
      dynamicPaymentToken,
      mismatchedEntry,
    ]) {
      expect(
        () => AccountCapabilities.fromJson(response),
        throwsFormatException,
      );
    }
  });

  test('account portal guard rejects same-host route confusion', () {
    expect(
      isTrustedAccountPortalUri(
        Uri.parse(
          'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower',
        ),
      ),
      isTrue,
    );
    for (final value in <String>[
      'https://pc.woozooo.com/not-official?item=profile&action=mypower',
      'https://pc.woozooo.com/mydisk.php?item=profile&action=mypower#confirm',
      'https://pc.woozooo.com/mydisk.php?item=profile&action=huiyuan&token=secret',
      'https://accounts.woozooo.com/mydisk.php?item=profile&action=mypower',
    ]) {
      expect(isTrustedAccountPortalUri(Uri.parse(value)), isFalse);
    }
  });

  test('AccountCapabilities rejects oversized lists and strings', () {
    final oversizedList = _accountResponse('vip')
      ..['entries'] = List<Object?>.generate(
        17,
        (_) => _accountEntry(
          id: 'permissions',
          item: 'profile',
          action: 'mypower',
        ),
      );
    final oversizedString = _accountResponse('vip');
    (oversizedString['membershipProfile']! as Map<String, Object?>)['reason'] =
        'x' * 513;

    expect(
      () => AccountCapabilities.fromJson(oversizedList),
      throwsFormatException,
    );
    expect(
      () => AccountCapabilities.fromJson(oversizedString),
      throwsFormatException,
    );
  });

  test('AccountCapabilities refuses payment-data capability', () {
    final response = _accountResponse('vip')..['acceptsPaymentData'] = true;
    expect(() => AccountCapabilities.fromJson(response), throwsFormatException);
  });

  test(
    'AccountCapabilities requires the complete read-only account schema',
    () {
      final missingPlan = _accountResponse('vip');
      (missingPlan['plans']! as List<Object?>).removeLast();
      final writablePersonalization = _accountResponse('vip');
      final firstSetting =
          (writablePersonalization['personalization']! as List<Object?>).first
              as Map<String, Object?>;
      firstSetting['writable'] = true;

      expect(
        () => AccountCapabilities.fromJson(missingPlan),
        throwsFormatException,
      );
      expect(
        () => AccountCapabilities.fromJson(writablePersonalization),
        throwsFormatException,
      );
    },
  );

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

Map<String, Object?> _accountResponse(String state) {
  const base = 'https://pc.woozooo.com/mydisk.php';
  final isVip = state == 'vip';
  return <String, Object?>{
    'authenticated': true,
    'userId': 'member-user',
    'accountPortalUrl': '$base?item=profile&action=mypower',
    'membershipPortalUrl': '$base?item=profile&action=huiyuan',
    'personalizationPortalUrl': '$base?item=profile&action=huiyuan',
    'membershipProfile': <String, Object?>{
      'state': state,
      'displayName': switch (state) {
        'vip' => '会员个性化',
        'free' => '普通用户',
        _ => '会员状态未知',
      },
      'level': isVip ? 'VIP' : null,
      'expiresAt': isVip ? '2027-07-30' : null,
      'reason': isVip ? '已从官方个人页识别' : '官方个人页未提供会员期限',
    },
    'entries': <Object?>[
      _accountEntry(id: 'permissions', item: 'profile', action: 'mypower'),
      _accountEntry(id: 'balance', item: 'profile', action: 'goods'),
      _accountEntry(id: 'fileUpgrade', item: 'profile', action: 'buygoods'),
      _accountEntry(id: 'downloadCashout', item: 'profile', action: 'exchange'),
      _accountEntry(id: 'cashoutRecords', item: 'profile', action: 'orders'),
      _accountEntry(id: 'invite', item: 'buddy', action: 'invite'),
      _accountEntry(id: 'password', item: 'profile', action: 'password'),
      _accountEntry(id: 'phone', item: 'profile', action: 'mypower'),
      _accountEntry(id: 'closeAccount', item: 'profile', action: 'mypower'),
    ],
    'facts': <Object?>[
      _fact('singleFileLimit', '单个文件大小', '220 MB'),
      _fact('storageStatistics', '云存储统计', '已统计'),
      _fact('downloadWithoutLogin', '下载免登录', '支持'),
      _fact('downloadSpeed', '下载速度', '高速'),
      _fact('downloadCount', '下载次数', '1000 次'),
      _fact('downloadTraffic', '下载流量', '10 GB'),
      _fact('storageCapacity', '存储空间', '10 GB'),
      _fact('allowedUploadTypes', '允许上传类型', '全部'),
    ],
    'plans': <Object?>[
      _plan('month1', '1个月'),
      _plan('month2', '2个月'),
      _plan('month6', '6个月'),
      _plan('year1', '1年'),
      _plan('monthly', '包月'),
      _plan('yearly', '包年'),
      _plan('downloadPack', '下载包'),
    ],
    'personalization': <Object?>[
      _personalization('adFreeDownloads', '免广告下载', enabled: true),
      _personalization('uploadTimeVisibility', '上传时间', enabled: true),
      _personalization('subfolders', '子文件夹', enabled: true),
      _personalization('search', '搜索', enabled: true),
      _personalization('defaultFilePassword', '新文件密码', enabled: false),
      _personalization('avatarUpload', '头像上传', value: '已设置'),
      _personalization('downloadPageTemplate', '下载页模板', value: '默认模板'),
      _personalization('publisherNickname', '发布者昵称', value: '会员个性化'),
      _personalization('dailyDownloadReport', '日下载报表', enabled: true),
      _personalization('fileRetention', '文件保存时间', value: '会员期限'),
      _personalization('directLinkDomain', '直链域名绑定', value: '未绑定'),
    ],
    'acceptsPaymentData': false,
  };
}

Map<String, Object?> _fact(String id, String label, String value) {
  return <String, Object?>{
    'id': id,
    'label': label,
    'value': value,
    'known': true,
  };
}

Map<String, Object?> _accountEntry({
  required String id,
  required String item,
  required String action,
}) {
  return <String, Object?>{
    'id': id,
    'title': id,
    'description': '蓝奏云官方个人中心入口',
    'portalUrl': 'https://pc.woozooo.com/mydisk.php?item=$item&action=$action',
    'available': true,
    'requiresOfficialConfirmation': id != 'permissions',
    'dangerous': id == 'closeAccount',
  };
}

Map<String, Object?> _plan(String id, String label) {
  return <String, Object?>{
    'id': id,
    'label': label,
    'detail': '价格与权益以蓝奏云官方页面为准',
    'priceLabel': null,
    'available': true,
  };
}

Map<String, Object?> _personalization(
  String id,
  String title, {
  bool? enabled,
  String? value,
}) {
  return <String, Object?>{
    'id': id,
    'title': title,
    'description': '蓝奏云会员个性化项目',
    'available': true,
    'enabled': enabled,
    'value': value,
    'writable': false,
    'reason': '修改需要蓝奏云官方确认',
  };
}
