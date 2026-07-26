import 'package:flutter/foundation.dart';

import '../models/cloud_item.dart';
import '../services/cloud_service.dart';

enum RecycleStatus { idle, loading, content, empty, error }

class RecycleController extends ChangeNotifier {
  RecycleController({
    required this.cloudService,
    required this.onSessionExpired,
  });

  final CloudService cloudService;
  final Future<void> Function(String message) onSessionExpired;

  RecycleStatus status = RecycleStatus.idle;
  String? errorMessage;
  bool operationRunning = false;
  bool _disposed = false;
  final List<CloudItem> _items = <CloudItem>[];
  final Set<String> selectedIds = <String>{};

  List<CloudItem> get items => List.unmodifiable(_items);
  bool get selectionMode => selectedIds.isNotEmpty;

  Future<void> load({bool refresh = false}) async {
    if (status == RecycleStatus.loading) return;
    if (!refresh || _items.isEmpty) status = RecycleStatus.loading;
    errorMessage = null;
    selectedIds.clear();
    _notify();
    try {
      final result = await cloudService.listRecycle();
      _items
        ..clear()
        ..addAll(result);
      status = _items.isEmpty ? RecycleStatus.empty : RecycleStatus.content;
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) await onSessionExpired(error.message);
      errorMessage = error.message;
      status = RecycleStatus.error;
    } on Object {
      errorMessage = '无法读取回收站';
      status = RecycleStatus.error;
    }
    _notify();
  }

  void toggleSelection(CloudItem item) {
    if (!selectedIds.add(item.id)) selectedIds.remove(item.id);
    _notify();
  }

  void selectAll() {
    selectedIds.addAll(_items.map((item) => item.id));
    _notify();
  }

  void clearSelection() {
    if (selectedIds.isEmpty) return;
    selectedIds.clear();
    _notify();
  }

  Iterable<CloudItem> get selectedItems =>
      _items.where((item) => selectedIds.contains(item.id));

  Future<String?> restore(Iterable<CloudItem> items) {
    return _operate(items, cloudService.restoreRecycle);
  }

  Future<String?> purge(Iterable<CloudItem> items) {
    return _operate(items, cloudService.purgeRecycle);
  }

  Future<String?> empty() async {
    if (operationRunning) return '已有操作正在进行';
    operationRunning = true;
    _notify();
    try {
      await cloudService.emptyRecycle();
      await load(refresh: true);
      return null;
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) await onSessionExpired(error.message);
      return error.message;
    } on Object {
      return '清空回收站失败';
    } finally {
      operationRunning = false;
      _notify();
    }
  }

  Future<String?> _operate(
    Iterable<CloudItem> values,
    Future<void> Function(CloudItem item) operation,
  ) async {
    if (operationRunning) return '已有操作正在进行';
    final items = values.toList(growable: false);
    if (items.isEmpty) return null;
    operationRunning = true;
    _notify();
    try {
      for (final item in items) {
        await operation(item);
      }
      await load(refresh: true);
      return null;
    } on CloudFailure catch (error) {
      if (error.isSessionExpired) await onSessionExpired(error.message);
      return error.message;
    } on Object {
      return '回收站操作失败';
    } finally {
      operationRunning = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
