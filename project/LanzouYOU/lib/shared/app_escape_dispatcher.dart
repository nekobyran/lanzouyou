import 'package:flutter/material.dart';

typedef AppEscapeHandler = bool Function();

/// Shared layered Escape policy for desktop-style Flutter applications.
///
/// Escape is consumed in this order:
/// 1. the top transient overlay/menu supplied by [closeTopTransientLayer];
/// 2. the top Navigator route (including dialogs and independent pages);
/// 3. a focused editable control on the root route;
/// 4. the app-specific fallback supplied by [onRootEscape].
///
/// Returning `true` from [closeTopTransientLayer] means that layer handled the
/// key and no lower layer is touched.
class AppEscapeDispatcher {
  const AppEscapeDispatcher({
    required this.navigatorKey,
    required this.closeTopTransientLayer,
    this.onRootEscape,
    this.editableTextConsumesEscape = true,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final AppEscapeHandler closeTopTransientLayer;
  final VoidCallback? onRootEscape;
  final bool editableTextConsumesEscape;

  void dispatch() {
    if (closeTopTransientLayer()) return;

    final navigator = navigatorKey.currentState;
    if (navigator?.canPop() == true) {
      navigator?.maybePop();
      return;
    }

    if (editableTextConsumesEscape && _editableTextHasPrimaryFocus()) {
      return;
    }

    onRootEscape?.call();
  }

  bool _editableTextHasPrimaryFocus() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}
