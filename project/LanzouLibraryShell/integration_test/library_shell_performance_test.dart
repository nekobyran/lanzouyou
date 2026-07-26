import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lanzou_library_shell/pages/library/library_list.dart';

import '../tool/library_shell_performance_harness.dart';

const _minimumMeasuredFrames = 120;
const _maximumPipelineBudgetMissPercent = 10.0;
const _maximumP95FrameTimeMs = 24.0;
const _maximumP99FrameTimeMs = 50.0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile 1000 item directory uses a real lazy scroll workload', (
    tester,
  ) async {
    expect(kProfileMode, isTrue, reason: '长列表性能测试必须使用 flutter drive --profile');
    final core = LibraryPerformanceCore();
    await tester.pumpWidget(buildLibraryPerformanceHarness(core: core));
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('compact-navigation-bar')).evaluate().isNotEmpty,
    );

    final navigation = find.byKey(const Key('compact-navigation-bar'));
    final directoryDestination = find.descendant(
      of: navigation,
      matching: find.text('目录'),
    );
    expect(directoryDestination, findsOneWidget);
    await tester.tap(directoryDestination);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('compact-source-overview-grid'))
          .evaluate()
          .isNotEmpty,
    );

    final overview = find.byKey(const Key('compact-source-overview-grid'));
    final source = find.descendant(
      of: overview,
      matching: find.text('1000 项性能目录'),
    );
    expect(source, findsOneWidget);
    await tester.tap(source);
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('compact-directory-grid')).evaluate().isNotEmpty,
    );
    expect(find.text('已显示 $libraryPerformanceItemCount 个项目'), findsOneWidget);

    final scrollView = find.byKey(const Key('directory-scroll-view'));
    expect(scrollView, findsOneWidget);
    final before = _builtItemIndices(tester);
    expect(before, isNotEmpty);
    expect(
      before.length,
      lessThan(80),
      reason: '1000 项目录必须保持 Sliver 惰性构建，不能一次创建全部条目',
    );
    await _pumpUntil(tester, () => core.assetFetchCount >= before.length);

    debugPrint('SHELL_PERF_SCROLL_START');
    await binding.watchPerformance(() async {
      for (var iteration = 0; iteration < 10; iteration++) {
        await tester.timedDrag(
          scrollView,
          const Offset(0, -1080),
          const Duration(milliseconds: 520),
          frequency: 60,
        );
        await tester.pump(const Duration(milliseconds: 80));
      }
    }, reportKey: 'profileLongList');
    debugPrint('SHELL_PERF_SCROLL_END');

    final after = _builtItemIndices(tester);
    expect(after, isNotEmpty);
    expect(after.first, greaterThan(before.first));
    expect(after.last, greaterThan(before.last));

    final summary =
        binding.reportData!['profileLongList']! as Map<String, dynamic>;
    final frameCount = summary['frame_count']! as int;
    final buildMisses = summary['missed_frame_build_budget_count']! as int;
    final rasterMisses =
        summary['missed_frame_rasterizer_budget_count']! as int;
    final buildTimes = (summary['frame_build_times']! as List).cast<int>();
    final rasterTimes = (summary['frame_rasterizer_times']! as List)
        .cast<int>();
    final totalFrameTimesMs = <double>[
      for (
        var index = 0;
        index < math.min(buildTimes.length, rasterTimes.length);
        index++
      )
        math.max(buildTimes[index], rasterTimes[index]) / 1000,
    ]..sort();
    final p95FrameTimeMs = _percentile(totalFrameTimesMs, 0.95);
    final p99FrameTimeMs = _percentile(totalFrameTimesMs, 0.99);
    expect(frameCount, greaterThanOrEqualTo(_minimumMeasuredFrames));
    expect(
      buildMisses * 100 / frameCount,
      lessThanOrEqualTo(_maximumPipelineBudgetMissPercent),
    );
    expect(
      rasterMisses * 100 / frameCount,
      lessThanOrEqualTo(_maximumPipelineBudgetMissPercent),
    );

    binding.reportData!['workload'] = <String, Object>{
      'buildMode': 'profile',
      'itemCount': libraryPerformanceItemCount,
      'lazyBuiltCountBefore': before.length,
      'beforeFirstIndex': before.first,
      'beforeLastIndex': before.last,
      'afterFirstIndex': after.first,
      'afterLastIndex': after.last,
      'visibleRangeChanged':
          before.first != after.first && before.last != after.last,
      'assetFetchCount': core.assetFetchCount,
      'scrollCount': 10,
      'frameTimeDefinition': 'max(buildDuration,rasterDuration)',
      'measuredP95FrameTimeMs': p95FrameTimeMs,
      'measuredP99FrameTimeMs': p99FrameTimeMs,
      'thresholds': <String, Object>{
        'minimumMeasuredFrames': _minimumMeasuredFrames,
        'maximumPipelineBudgetMissPercent': _maximumPipelineBudgetMissPercent,
        'maximumP95FrameTimeMs': _maximumP95FrameTimeMs,
        'maximumP99FrameTimeMs': _maximumP99FrameTimeMs,
      },
    };
  });
}

double _percentile(List<double> sorted, double fraction) {
  if (sorted.isEmpty) throw TestFailure('未采集到 Flutter FrameTiming');
  final position = (sorted.length - 1) * fraction;
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return sorted[lower];
  final weight = position - lower;
  return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

List<int> _builtItemIndices(WidgetTester tester) {
  final indices =
      tester
          .widgetList<LibraryCompactGridTile>(
            find.byType(LibraryCompactGridTile),
          )
          .map(
            (tile) => libraryPerformanceIndexByStableKey[tile.item.stableKey],
          )
          .whereType<int>()
          .toSet()
          .toList()
        ..sort();
  return indices;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure('等待性能验收界面超时');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 250));
}
