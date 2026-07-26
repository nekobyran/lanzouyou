import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/services/json_core_transport.dart';
import 'package:lanzouyou/models/directory_upload.dart';
import 'package:lanzouyou/services/rust_cloud_service.dart';

void main() {
  test(
    'Rust adapter sends one directory upload command and parses result',
    () async {
      final transport = _DirectoryTransport();
      final cloud = RustCloudService.testHarness(transport);

      final result = await cloud.uploadDirectory(
        '-1',
        r'D:\apps',
        compatibilityWrap: true,
        kind: 'file',
        autoApkIcons: true,
        operationId: 'directory-1',
      );

      expect(result.state, DirectoryUploadState.succeeded);
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single, <String, Object?>{
        'op': 'upload_directory',
        'folderId': '-1',
        'path': r'D:\apps',
        'compatWrap': true,
        'kind': 'file',
        'autoApkIcons': true,
        'operationId': 'directory-1',
      });
    },
  );
}

class _DirectoryTransport implements JsonCoreTransport {
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  @override
  Future<String> dispatch(String request) async {
    requests.add((jsonDecode(request) as Map).cast<String, Object?>());
    return jsonEncode(<String, Object?>{
      'ok': true,
      'data': <String, Object?>{
        'state': 'succeeded',
        'atomic': false,
        'rootName': 'apps',
        'remoteRootId': '10',
        'partialRemoteRetained': true,
        'totalDirectories': 1,
        'createdDirectories': 1,
        'totalFiles': 0,
        'processedFiles': 0,
        'uploadedFiles': 0,
        'totalBytes': 0,
        'uploadedBytes': 0,
        'autoApkIcons': true,
        'iconBoundFiles': 0,
        'failures': <Object?>[],
      },
      'error': null,
    });
  }
}
