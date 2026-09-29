import 'package:flutter/material.dart';

// Material Files 2026-08-06 (fc125003) builds dialogs with
// MaterialAlertDialogBuilder and Material Components 1.13.0. Its Material 3
// dialog theme resolves to m3_motion_fade_enter/exit. Keep these tokens in sync
// with those Android resources rather than approximating the motion by eye.
const appMaterialDialogEnterDuration = Duration(milliseconds: 400);
const appMaterialDialogExitDuration = Duration(milliseconds: 150);
const appMaterialDialogBeginScale = 0.80;
const appMaterialDialogEnterCurve = Cubic(0.1, 0.7, 0.1, 1);
const appMaterialDialogExitCurve = Cubic(0.3, 0, 0.8, 0.2);

/// Opens an official Material dialog with Material Files' Material 3 motion.
Future<T?> showAppMaterialDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push<T>(
    AppMaterialDialogRoute<T>(
      context: context,
      builder: builder,
      themes: themes,
      barrierDismissible: barrierDismissible,
      reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
    ),
  );
}

class AppMaterialDialogRoute<T> extends DialogRoute<T> {
  AppMaterialDialogRoute({
    required super.context,
    required super.builder,
    required this.reduceMotion,
    super.themes,
    super.barrierDismissible = true,
  }) : super(
         traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
         animationStyle: const AnimationStyle(
           duration: appMaterialDialogEnterDuration,
           reverseDuration: appMaterialDialogExitDuration,
         ),
       );

  final bool reduceMotion;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : appMaterialDialogEnterDuration;

  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : appMaterialDialogExitDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion) return child;
    final scale = _AppMaterialDialogScaleAnimation(animation);
    final opacity = _AppMaterialDialogOpacityAnimation(animation);
    return FadeTransition(
      key: const ValueKey('app-material-dialog-fade'),
      opacity: opacity,
      child: ScaleTransition(
        key: const ValueKey('app-material-dialog-scale'),
        scale: scale,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

class _AppMaterialDialogScaleAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _AppMaterialDialogScaleAnimation(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value {
    // m3_motion_fade_exit.xml only fades; it does not shrink the dialog.
    if (parent.status == AnimationStatus.reverse) return 1;
    final progress = appMaterialDialogEnterCurve.transform(parent.value);
    return appMaterialDialogBeginScale +
        (1 - appMaterialDialogBeginScale) * progress;
  }
}

class _AppMaterialDialogOpacityAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _AppMaterialDialogOpacityAnimation(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value {
    if (parent.status == AnimationStatus.reverse) {
      final exitProgress = 1 - parent.value;
      return 1 - appMaterialDialogExitCurve.transform(exitProgress);
    }
    return appMaterialDialogEnterCurve.transform(parent.value);
  }
}

/// Opens an official Material [AlertDialog] with persistent inline validation.
///
/// The dialog follows the interaction pattern used by MaterialFiles: validation
/// owns dismissal, the IME confirm action submits, and invalid input keeps the
/// dialog open instead of relying on the default positive-button auto-dismiss.
Future<String?> showAppMaterialNameDialog(
  BuildContext context, {
  String title = '新建项目',
  String label = '项目名称',
  String cancelLabel = '取消',
  String confirmLabel = '创建',
}) {
  return showAppMaterialDialog<String>(
    context,
    builder: (context) => AppMaterialNameDialog(
      title: title,
      label: label,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
    ),
  );
}

class AppMaterialNameDialog extends StatefulWidget {
  const AppMaterialNameDialog({
    super.key,
    required this.title,
    required this.label,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final String title;
  final String label;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<AppMaterialNameDialog> createState() => _AppMaterialNameDialogState();
}

class _AppMaterialNameDialogState extends State<AppMaterialNameDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _errorText = '名称不能为空');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('official-material-dialog'),
      icon: const Icon(Icons.create_new_folder_outlined),
      title: Text(widget.title),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
        child: TextField(
          key: const ValueKey('material-dialog-name-field'),
          controller: _controller,
          focusNode: _focusNode,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_errorText != null) setState(() => _errorText = null);
          },
          decoration: InputDecoration(
            labelText: widget.label,
            errorText: _errorText,
            helperText: '确认前在弹窗内完成校验，错误时保持打开。',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
