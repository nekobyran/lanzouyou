import 'package:flutter/widgets.dart';

typedef AppValueWidgetBuilder<T> =
    Widget Function(BuildContext context, T value, Widget? child);

/// Rebuilds only when the selected immutable value changes.
///
/// This keeps high-frequency controller progress/description notifications
/// local instead of rebuilding the application scaffold and navigation.
class AppListenableSelector<T> extends StatefulWidget {
  const AppListenableSelector({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final T Function() selector;
  final AppValueWidgetBuilder<T> builder;
  final Widget? child;

  @override
  State<AppListenableSelector<T>> createState() =>
      _AppListenableSelectorState<T>();
}

class _AppListenableSelectorState<T> extends State<AppListenableSelector<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector();
    widget.listenable.addListener(_handleChange);
  }

  @override
  void didUpdateWidget(covariant AppListenableSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_handleChange);
      widget.listenable.addListener(_handleChange);
    }
    final next = widget.selector();
    if (next != _value) _value = next;
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    final next = widget.selector();
    if (next == _value) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);
}
