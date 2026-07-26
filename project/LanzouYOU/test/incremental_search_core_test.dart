import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/pages/public_library/incremental_search_core.dart';

void main() {
  test('parses opaque cursor batches paused state and operation revision', () {
    final read = IncrementalSearchRead.fromJson({
      'cursor': 'sj.g0011223344556677.2',
      'acknowledgedCursor': 'sj.g0011223344556677.0',
      'hasMore': false,
      'batches': [
        {
          'cursor': 'sj.g0011223344556677.2',
          'revision': 2,
          'items': const [],
          'sources': [
            {
              'sourceId': 'source-1',
              'title': '真实来源',
              'found': 3,
              'completed': true,
            },
          ],
          'state': {'state': 'paused', 'operationRevision': 9},
        },
      ],
    });

    expect(read.batches.single.state?.state.name, 'paused');
    expect(read.batches.single.state?.operationRevision, 9);
    expect(read.batches.single.sources.single.found, 3);
  });

  test('rejects oversized batches and unknown response fields', () {
    expect(
      () => IncrementalSearchBatch.fromJson({
        'cursor': 'sj.g0011223344556677.1',
        'revision': 1,
        'items': List<Object?>.filled(101, const {}),
        'sources': const [],
      }),
      throwsFormatException,
    );
    expect(
      () => IncrementalSearchStart.fromJson(const {
        'operationId': 'search-1',
        'cursor': 'sj.g0011223344556677.0',
        'state': 'running',
        'revision': 1,
        'legacy': true,
      }),
      throwsFormatException,
    );
  });
}
