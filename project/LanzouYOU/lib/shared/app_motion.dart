import 'dart:async';

import 'package:flutter/material.dart';

enum AppMotionTransition { fadeThrough, slide, fade, size }

/// Shared Material motion tokens and transitions for every LanzouYOU surface.
///
/// All duration lookups honor both the operating-system accessibility setting
/// and the user's persisted in-app preference. State text, icons, and semantics
/// remain present when motion is disabled, so animation is never the only cue.
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 320);
  static const standard = medium;

  static const enterCurve = Curves.easeOutCubic;
  static const exitCurve = Curves.easeInCubic;
  static const standardCurve = Curves.easeInOutCubicEmphasized;
  static const curve = enterCurve;

  static bool isReduced(BuildContext context) {
    final platformReduced =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return platformReduced ||
        AppMotionScope.maybeOf(context)?.reduceMotion == true;
  }

  static Duration fastFor(BuildContext context) =>
      isReduced(context) ? Duration.zero : fast;

  static Duration mediumFor(BuildContext context) =>
      isReduced(context) ? Duration.zero : medium;

  static Duration standardFor(BuildContext context) => mediumFor(context);

  static Duration slowFor(BuildContext context) =>
      isReduced(context) ? Duration.zero : slow;

  static Widget transition(
    AppMotionTransition type,
    Widget child,
    Animation<double> animation,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: enterCurve,
      reverseCurve: exitCurve,
    );
    return switch (type) {
      AppMotionTransition.fadeThrough => FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
          child: child,
        ),
      ),
      AppMotionTransition.slide => FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.025, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ),
      AppMotionTransition.fade => FadeTransition(opacity: curved, child: child),
      AppMotionTransition.size => FadeTransition(
        opacity: curved,
        child: SizeTransition(
          sizeFactor: curved,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
    };
  }
}

class AppMotionScope extends InheritedWidget {
  const AppMotionScope({
    required this.reduceMotion,
    required super.child,
    super.key,
  });

  final bool reduceMotion;

  static AppMotionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppMotionScope>();

  @override
  bool updateShouldNotify(AppMotionScope oldWidget) =>
      reduceMotion != oldWidget.reduceMotion;
}

class AppMotionSwitcher extends StatelessWidget {
  const AppMotionSwitcher({
    required this.child,
    this.transition = AppMotionTransition.fadeThrough,
    this.alignment = Alignment.center,
    super.key,
  });

  final Widget child;
  final AppMotionTransition transition;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.mediumFor(context),
      reverseDuration: AppMotion.fastFor(context),
      switchInCurve: AppMotion.enterCurve,
      switchOutCurve: AppMotion.exitCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        fit: StackFit.passthrough,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) =>
          AppMotion.transition(transition, child, animation),
      child: child,
    );
  }
}

class AppMotionAnimatedSize extends StatelessWidget {
  const AppMotionAnimatedSize({
    required this.child,
    this.alignment = Alignment.topCenter,
    super.key,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppMotion.mediumFor(context),
      reverseDuration: AppMotion.fastFor(context),
      curve: AppMotion.standardCurve,
      alignment: alignment,
      child: child,
    );
  }
}

class AppMotionListItem extends StatelessWidget {
  const AppMotionListItem({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: AppMotion.mediumFor(context),
      curve: AppMotion.enterCurve,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 8),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class AppMotionSelection extends StatelessWidget {
  const AppMotionSelection({
    required this.selected,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    super.key,
  });

  final bool selected;
  final Widget child;
  final BorderRadiusGeometry borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: AnimatedContainer(
        duration: AppMotion.fastFor(context),
        curve: AppMotion.standardCurve,
        decoration: BoxDecoration(
          color: selected ? colors.secondaryContainer : Colors.transparent,
          borderRadius: borderRadius,
        ),
        child: child,
      ),
    );
  }
}

/// Keeps every top-level destination alive while animating only the outgoing
/// and incoming page. Inactive pages are offstage with tickers and semantics
/// disabled, avoiding both state loss and needless hidden-page work.
class AppMotionPageStack extends StatefulWidget {
  const AppMotionPageStack({
    required this.index,
    required this.children,
    super.key,
  });

  final int index;
  final List<Widget> children;

  @override
  State<AppMotionPageStack> createState() => _AppMotionPageStackState();
}

class _AppMotionPageStackState extends State<AppMotionPageStack> {
  int? _previousIndex;
  Timer? _settleTimer;

  @override
  void didUpdateWidget(AppMotionPageStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index) return;
    _settleTimer?.cancel();
    _previousIndex = oldWidget.index;
    final duration = AppMotion.mediumFor(context);
    if (duration == Duration.zero) {
      _previousIndex = null;
      return;
    }
    _settleTimer = Timer(duration, () {
      if (mounted) setState(() => _previousIndex = null);
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.index >= 0 && widget.index < widget.children.length);
    return Stack(
      fit: StackFit.expand,
      children: List<Widget>.generate(widget.children.length, (index) {
        final selected = index == widget.index;
        final transitioningOut = index == _previousIndex;
        final active = selected || transitioningOut;
        return Offstage(
          offstage: !active,
          child: TickerMode(
            enabled: selected,
            child: ExcludeSemantics(
              excluding: !selected,
              child: IgnorePointer(
                ignoring: !selected,
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: AppMotion.mediumFor(context),
                  curve: selected ? AppMotion.enterCurve : AppMotion.exitCurve,
                  child: widget.children[index],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
