import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/models/directory_upload.dart';

void main() {
  test(
    'directory upload result preserves partial residual and failure stage',
    () {
      final result = DirectoryUploadResult.fromJson(<String, Object?>{
        'state': 'partial',
        'atomic': false,
        'rootName': '软件合集',
        'remoteRootId': '91',
        'partialRemoteRetained': true,
        'totalDirectories': 3,
        'createdDirectories': 2,
        'totalFiles': 4,
        'processedFiles': 4,
        'uploadedFiles': 3,
        'totalBytes': 400,
        'uploadedBytes': 300,
        'autoApkIcons': true,
        'iconBoundFiles': 2,
        'failures': <Map<String, Object?>>[
          <String, Object?>{
            'relativePath': '工具/failed.apk',
            'stage': 'upload_file',
            'code': 'remote_error',
            'message': '上传失败',
            'retriable': true,
          },
        ],
      });

      expect(result.state, DirectoryUploadState.partial);
      expect(result.hasRemoteChanges, isTrue);
      expect(result.remoteRootId, '91');
      expect(result.failures.single.relativePath, '工具/failed.apk');
      expect(
        result.failures.single.stage,
        DirectoryUploadFailureStage.uploadFile,
      );
      expect(result.summary, contains('3/4'));
      expect(result.summary, contains('已创建云端目录「软件合集」'));
      expect(result.summary, isNot(contains('91')));
    },
  );

  test(
    'directory upload result rejects atomic or inconsistent success claims',
    () {
      Map<String, Object?> success() => <String, Object?>{
        'state': 'succeeded',
        'atomic': false,
        'rootName': 'apps',
        'remoteRootId': '10',
        'partialRemoteRetained': true,
        'totalDirectories': 1,
        'createdDirectories': 1,
        'totalFiles': 1,
        'processedFiles': 1,
        'uploadedFiles': 1,
        'totalBytes': 10,
        'uploadedBytes': 10,
        'autoApkIcons': false,
        'iconBoundFiles': 0,
        'failures': <Object?>[],
      };

      final atomic = success()..['atomic'] = true;
      expect(
        () => DirectoryUploadResult.fromJson(atomic),
        throwsFormatException,
      );

      final falseSuccess = success()
        ..['uploadedFiles'] = 0
        ..['failures'] = <Map<String, Object?>>[
          <String, Object?>{
            'relativePath': 'a.apk',
            'stage': 'upload_file',
            'code': 'remote_error',
            'message': 'failed',
            'retriable': false,
          },
        ];
      expect(
        () => DirectoryUploadResult.fromJson(falseSuccess),
        throwsFormatException,
      );

      for (final legacy in <String>[
        'localRootPath',
        'residualRemoteRootId',
        'autoFileIcons',
      ]) {
        final injected = success()..[legacy] = 'must-not-pass';
        expect(
          () => DirectoryUploadResult.fromJson(injected),
          throwsFormatException,
          reason: legacy,
        );
      }
    },
  );

  test('directory upload failures reject absolute and traversal paths', () {
    Map<String, Object?> failure(String path) => <String, Object?>{
      'relativePath': path,
      'stage': 'prepare_icon',
      'code': 'invalid_argument',
      'message': 'bad',
      'retriable': false,
    };

    expect(
      () => DirectoryUploadFailure.fromJson(failure(r'C:\secret.apk')),
      throwsFormatException,
    );
    expect(
      () => DirectoryUploadFailure.fromJson(failure('../secret.apk')),
      throwsFormatException,
    );
    expect(
      DirectoryUploadFailure.fromJson(failure('nested/app.apk')).relativePath,
      'nested/app.apk',
    );
  });
}
