import 'package:flutter/widgets.dart';

extension AppSizeMetrics on Size {
  bool get isPiliPortrait => width < 600 || height >= width;
  bool get isWideLandscape => !isPiliPortrait;
}

class AppAdaptiveMetrics {
  const AppAdaptiveMetrics._();

  static bool isPortrait(BuildContext context) {
    return MediaQuery.sizeOf(context).isPiliPortrait;
  }

  static bool useVerticalNavigation(BuildContext context) {
    return MediaQuery.sizeOf(context).isWideLandscape;
  }
}
