import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/pages/public_library/public_library.dart';

void main() {
  test('catalog models parse the Rust batch contract without credentials', () {
    final summary = PublicLibraryCatalogSummary.fromJson(const {
      'revision': 'catalog-r7',
      'officialCount': 597,
      'compositeCount': 9,
      'nodeCount': 3370,
      'searchableCount': 591,
    });
    final page = PublicLibraryCatalogPage.fromJson(const {
      'revision': 'catalog-r7',
      'total': 606,
      'nextCursor': 'opaque:100',
      'hasMore': true,
      'nodes': [
        {
          'id': 'source-1',
          'parentId': '',
          'kind': 'remoteSource',
          'sourceId': 'source-1',
          'title': '公开软件库',
          'publisher': '发布者',
          'description': '真实目录',
          'iconUrl': '',
          'size': '',
          'time': '',
          'searchable': true,
          'childDirectory': true,
          'originPath': 's/1',
          'originUrl': 'https://www.lanzouw.com/b123',
          'shareUrl': 'https://www.lanzouw.com/b123',
          'hasChildren': true,
        },
      ],
    });

    expect(summary.officialCount, 597);
    expect(summary.totalSourceCount, 606);
    expect(page.nodes.single.kind, PublicLibraryNodeKind.remoteSource);
    expect(page.nodes.single.originPath, 's/1');
    expect(page.nextCursor, 'opaque:100');
    expect(page.toString(), isNot(contains('password')));
  });

  test('catalog parser rejects unknown node kinds and credential fields', () {
    Map<String, Object?> node({required String kind}) => <String, Object?>{
      'id': 'node-1',
      'parentId': '',
      'kind': kind,
      'sourceId': 'source-1',
      'title': '节点',
      'publisher': '',
      'description': '',
      'iconUrl': '',
      'size': '',
      'time': '',
      'searchable': false,
      'childDirectory': false,
      'originPath': '',
      'originUrl': '',
      'shareUrl': '',
      'hasChildren': false,
    };

    expect(
      () => PublicLibraryCatalogNode.fromJson(node(kind: 'legacySource')),
      throwsFormatException,
    );
    expect(
      () => PublicLibraryCatalogNode.fromJson(
        node(kind: 'remoteSource')..['password'] = 'must-not-cross-ffi',
      ),
      throwsFormatException,
    );
  });
}
