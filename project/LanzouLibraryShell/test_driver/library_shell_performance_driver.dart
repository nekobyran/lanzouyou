import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data == null) throw StateError('性能测试未返回可机读数据');
    final frameTiming = (data['profileLongList']! as Map)
        .cast<String, dynamic>();
    final workload = (data['workload']! as Map).cast<String, dynamic>();
    final buildTimes = (frameTiming['frame_build_times']! as List)
        .cast<num>()
        .map((value) => value.toInt())
        .toList(growable: false);
    final rasterTimes = (frameTiming['frame_rasterizer_times']! as List)
        .cast<num>()
        .map((value) => value.toInt())
        .toList(growable: false);
    final count = math.min(buildTimes.length, rasterTimes.length);
    if (count == 0) throw StateError('性能测试未采集到 Flutter FrameTiming');
    final totalFrameTimesMs = <double>[
      for (var index = 0; index < count; index++)
        math.max(buildTimes[index], rasterTimes[index]) / 1000,
    ]..sort();
    const budgetUs = 16667;
    final jankyFrames = [
      for (var index = 0; index < count; index++)
        if (buildTimes[index] > budgetUs || rasterTimes[index] > budgetUs)
          index,
    ].length;
    final thresholds = (workload['thresholds']! as Map).cast<String, dynamic>();
    final buildMisses = frameTiming['missed_frame_build_budget_count']! as int;
    final rasterMisses =
        frameTiming['missed_frame_rasterizer_budget_count']! as int;
    final p95 = _percentile(totalFrameTimesMs, 0.95);
    final p99 = _percentile(totalFrameTimesMs, 0.99);
    final qualityPassed =
        count >= (thresholds['minimumMeasuredFrames']! as num) &&
        buildMisses * 100 / count <=
            (thresholds['maximumPipelineBudgetMissPercent']! as num) &&
        rasterMisses * 100 / count <=
            (thresholds['maximumPipelineBudgetMissPercent']! as num) &&
        p95 <= (thresholds['maximumP95FrameTimeMs']! as num) &&
        p99 <= (thresholds['maximumP99FrameTimeMs']! as num);
    final output = <String, Object?>{
      'schemaVersion': 1,
      'workload': workload,
      'flutterFrames': <String, Object>{
        'frameCount': count,
        'jankyFrames': jankyFrames,
        'jankyPercent': _round(jankyFrames * 100 / count),
        'p50Ms': _round(_percentile(totalFrameTimesMs, 0.50)),
        'p90Ms': _round(_percentile(totalFrameTimesMs, 0.90)),
        'p95Ms': _round(p95),
        'p99Ms': _round(p99),
        'buildBudgetMisses': buildMisses,
        'rasterBudgetMisses': rasterMisses,
        'averageBuildMs': frameTiming['average_frame_build_time_millis']!,
        'averageRasterMs': frameTiming['average_frame_rasterizer_time_millis']!,
        'worstBuildMs': frameTiming['worst_frame_build_time_millis']!,
        'worstRasterMs': frameTiming['worst_frame_rasterizer_time_millis']!,
      },
      'thresholdsPassed': qualityPassed,
      'rawFrameTiming': frameTiming,
    };
    final target = File(
      Platform.environment['SHELL_PERF_REPORT'] ??
          'build/performance/library_shell_profile_frame_metrics.json',
    );
    await target.parent.create(recursive: true);
    await target.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
      flush: true,
    );
    if (!qualityPassed) {
      throw StateError('profile performance thresholds failed');
    }
  },
);

double _percentile(List<double> sorted, double fraction) {
  final position = (sorted.length - 1) * fraction;
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return sorted[lower];
  final weight = position - lower;
  return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

double _round(num value) => (value * 1000).round() / 1000;
