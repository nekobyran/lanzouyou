import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_ui_tokens.dart';

abstract final class WindowsChromeContract {
  static const captionVisualChannel = 'app/windows_caption_visuals';
}

class WindowChrome extends StatefulWidget {
  const WindowChrome({
    super.key,
    required this.child,
    required this.title,
    required this.titleIcon,
  });

  final Widget child;
  final String title;
  final IconData titleIcon;

  @override
  State<WindowChrome> createState() => _WindowChromeState();
}

class _WindowChromeState extends State<WindowChrome> {
  static const _channel = MethodChannel(
    WindowsChromeContract.captionVisualChannel,
  );

  int _hoveredButton = 0;
  int _pressedButton = 0;
  bool _maximized = false;

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    if (_isWindows) {
      _channel.setMethodCallHandler(_handleCaptionVisualUpdate);
    }
  }

  @override
  void dispose() {
    if (_isWindows) {
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<void> _handleCaptionVisualUpdate(MethodCall call) async {
    if (call.method != 'update' || call.arguments is! Map) return;
    final arguments = call.arguments as Map;
    final hovered = arguments['hovered'];
    final pressed = arguments['pressed'];
    final maximized = arguments['maximized'];
    if (hovered is! int || pressed is! int || maximized is! bool || !mounted) {
      return;
    }
    setState(() {
      _hoveredButton = hovered;
      _pressedButton = pressed;
      _maximized = maximized;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isWindows) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        children: [
          _WindowsTitleBar(
            title: widget.title,
            titleIcon: widget.titleIcon,
            hoveredButton: _hoveredButton,
            pressedButton: _pressedButton,
            maximized: _maximized,
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

class _WindowsTitleBar extends StatelessWidget {
  const _WindowsTitleBar({
    required this.title,
    required this.titleIcon,
    required this.hoveredButton,
    required this.pressedButton,
    required this.maximized,
  });

  final String title;
  final IconData titleIcon;
  final int hoveredButton;
  final int pressedButton;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '$title window title bar',
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('windows-custom-titlebar'),
          height: AppUiTokens.windowsTitleBarHeight,
          color: scheme.surface,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: 12,
                  right: AppUiTokens.windowsCaptionButtonsWidth + 12,
                ),
                child: Row(
                  children: [
                    Icon(titleIcon, size: 16, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.topRight,
                child: _CaptionButtonVisuals(
                  hoveredButton: hoveredButton,
                  pressedButton: pressedButton,
                  maximized: maximized,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptionButtonVisuals extends StatelessWidget {
  const _CaptionButtonVisuals({
    required this.hoveredButton,
    required this.pressedButton,
    required this.maximized,
  });

  final int hoveredButton;
  final int pressedButton;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('windows-caption-visuals'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButtonVisual(
          buttonId: 1,
          glyph: '\uE921',
          semanticLabel: 'Minimize',
          hoveredButton: hoveredButton,
          pressedButton: pressedButton,
        ),
        _CaptionButtonVisual(
          buttonId: 2,
          glyph: maximized ? '\uE923' : '\uE922',
          semanticLabel: maximized ? 'Restore' : 'Maximize',
          hoveredButton: hoveredButton,
          pressedButton: pressedButton,
        ),
        _CaptionButtonVisual(
          buttonId: 3,
          glyph: '\uE8BB',
          semanticLabel: 'Close',
          hoveredButton: hoveredButton,
          pressedButton: pressedButton,
          danger: true,
        ),
      ],
    );
  }
}

class _CaptionButtonVisual extends StatelessWidget {
  const _CaptionButtonVisual({
    required this.buttonId,
    required this.glyph,
    required this.semanticLabel,
    required this.hoveredButton,
    required this.pressedButton,
    this.danger = false,
  });

  final int buttonId;
  final String glyph;
  final String semanticLabel;
  final int hoveredButton;
  final int pressedButton;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hovered = hoveredButton == buttonId;
    final pressed = pressedButton == buttonId;
    final background = pressed
        ? danger
              ? const Color(0xFFC50F1F)
              : scheme.onSurface.withValues(alpha: .12)
        : hovered
        ? danger
              ? const Color(0xFFE81123)
              : scheme.onSurface.withValues(alpha: .08)
        : Colors.transparent;
    final foreground = danger && (hovered || pressed)
        ? Colors.white
        : scheme.onSurfaceVariant;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      button: true,
      label: semanticLabel,
      child: AnimatedContainer(
        key: ValueKey('windows-caption-button-$buttonId'),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        width: AppUiTokens.windowsCaptionButtonWidth,
        height: AppUiTokens.windowsTitleBarHeight,
        color: background,
        alignment: Alignment.center,
        child: Text(
          glyph,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: foreground,
            fontFamily: 'Segoe Fluent Icons',
            fontFamilyFallback: const ['Segoe MDL2 Assets'],
            fontSize: 10,
            height: 1,
          ),
        ),
      ),
    );
  }
}

