import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_escape_dispatcher.dart';
import 'window_chrome.dart';

/// Reusable Windows/desktop application shell.
///
/// It centralizes the custom Windows chrome and the layered Escape contract so
/// feature pages do not recreate platform behavior independently.
class AppWindowsShell extends StatelessWidget {
  const AppWindowsShell({
    super.key,
    required this.navigatorKey,
    required this.title,
    required this.child,
    required this.closeTopTransientLayer,
    this.onRootEscape,
    this.titleIcon = Icons.apps_rounded,
    this.editableTextConsumesEscape = true,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final String title;
  final Widget child;
  final AppEscapeHandler closeTopTransientLayer;
  final VoidCallback? onRootEscape;
  final IconData titleIcon;
  final bool editableTextConsumesEscape;

  @override
  Widget build(BuildContext context) {
    final escapeDispatcher = AppEscapeDispatcher(
      navigatorKey: navigatorKey,
      closeTopTransientLayer: closeTopTransientLayer,
      onRootEscape: onRootEscape,
      editableTextConsumesEscape: editableTextConsumesEscape,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            escapeDispatcher.dispatch,
      },
      child: Focus(
        autofocus: true,
        child: WindowChrome(title: title, titleIcon: titleIcon, child: child),
      ),
    );
  }
}
