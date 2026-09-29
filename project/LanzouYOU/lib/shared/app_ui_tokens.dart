import 'package:flutter/material.dart';

class AppUiTokens {
  const AppUiTokens._();

  static const Color seed = Color(0xFF6750A4);

  static const double cardRadius = 12;
  static const double listTileRadius = 12;
  static const double navigationRailWidth = 80;
  static const double searchBoxMaxWidth = 520;
  static const double searchBoxLandscapeMaxWidth = 720;
  static const double searchBoxHeight = 56;
  static const double searchStageHorizontalPadding = 24;
  static const double windowsTitleBarHeight = 32;
  static const double windowsCaptionButtonWidth = 46;
  static const double windowsCaptionButtonsWidth =
      windowsCaptionButtonWidth * 3;
  // Gap between interactive AppBar controls and the caption strip.
  static const double windowsCaptionContentGap = 8;
  static const double favoritesSidebarLandscapeWidth = 200;
  static const double favoritesSidebarPortraitWidth = 240;

  // Web chrome keeps browser controls compact on desktop while preserving the
  // Material minimum touch target on Android.
  static const double webTabHeight = 36;
  static const double webTabWidth = 220;
  static const double webTabRadius = 16;
  static const double webAddressBarDesktopHeight = 40;
  static const double webAddressBarTouchHeight = 48;
}
