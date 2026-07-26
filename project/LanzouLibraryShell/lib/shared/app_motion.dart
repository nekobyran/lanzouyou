import 'package:flutter/material.dart';

/// Shared, causal motion tokens for the library shell.
///
/// Motion is never the only state indicator. Every caller must also expose the
/// resulting state through text, iconography, selection, or semantics.
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 140);
  static const standard = Duration(milliseconds: 220);
  static const emphasized = Duration(milliseconds: 320);

  static const enterCurve = Curves.easeOutCubic;
  static const exitCurve = Curves.easeInCubic;
  static const emphasizedCurve = Curves.easeInOutCubicEmphasized;

  static bool isEnabled(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    return media?.disableAnimations != true &&
        media?.accessibleNavigation != true;
  }

  static Duration duration(BuildContext context, [Duration token = standard]) =>
      isEnabled(context) ? token : Duration.zero;
}

/// Introduces only the new child, so state changes do not keep an expensive
/// outgoing list or image tree alive during the transition.
class AppMotionEntrance extends StatelessWidget {
  const AppMotionEntrance({
    super.key,
    required this.child,
    this.duration = AppMotion.standard,
    this.offset = const Offset(0, 0.025),
  });

  final Widget child;
  final Duration duration;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    final resolvedDuration = AppMotion.duration(context, duration);
    if (resolvedDuration == Duration.zero) return child;
    return TweenAnimationBuilder<double>(
      duration: resolvedDuration,
      curve: AppMotion.enterCurve,
      tween: Tween(begin: 0, end: 1),
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: FractionalTranslation(
          translation: Offset(offset.dx * (1 - value), offset.dy * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}

/// Switches a small state subtree with causal fade motion.
///
/// Callers must key the child by the low-frequency semantic state, never by a
/// byte counter or timestamp. This keeps progress polling from restarting an
/// animation while queued/resolving/cancelling/terminal changes stay visible.
class AppMotionSwitcher extends StatelessWidget {
  const AppMotionSwitcher({
    super.key,
    required this.child,
    this.duration = AppMotion.fast,
  });

  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final resolvedDuration = AppMotion.duration(context, duration);
    if (resolvedDuration == Duration.zero) return child;
    return AnimatedSwitcher(
      duration: resolvedDuration,
      reverseDuration: resolvedDuration,
      switchInCurve: AppMotion.enterCurve,
      switchOutCurve: AppMotion.exitCurve,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: child,
    );
  }
}
