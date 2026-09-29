import 'package:flutter/material.dart';

import '../app_ui_tokens.dart';
import 'adaptive_metrics.dart';

@immutable
class AppNavigationDestination {
  const AppNavigationDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// One destination model drives both Material navigation presentations.
class AppAdaptiveNavigationBar extends StatelessWidget {
  const AppAdaptiveNavigationBar({
    super.key,
    required this.body,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onLandscapeSearch,
    this.applicationIcon,
    this.applicationName,
  });

  final Widget body;
  final List<AppNavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onLandscapeSearch;
  final Widget? applicationIcon;
  final String? applicationName;

  @override
  Widget build(BuildContext context) {
    if (AppAdaptiveMetrics.useVerticalNavigation(context)) {
      final navigationColor = Theme.of(context).colorScheme.surface;
      final railExtended = MediaQuery.sizeOf(context).width >= 1200;
      return Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NavigationRail(
                key: const ValueKey('wide-navigation'),
                backgroundColor: navigationColor,
                minWidth: AppUiTokens.navigationRailWidth,
                groupAlignment: 0,
                leadingAtTop: true,
                extended: railExtended,
                labelType: railExtended
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                leading: onLandscapeSearch != null
                    ? IconButton.filledTonal(
                        key: const ValueKey('app-landscape-search'),
                        tooltip: '搜索',
                        onPressed: onLandscapeSearch,
                        icon: const Icon(Icons.search_rounded),
                        style: IconButton.styleFrom(
                          minimumSize: const Size.square(56),
                          maximumSize: const Size.square(56),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      )
                    : applicationIcon == null && applicationName == null
                    ? null
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ?applicationIcon,
                          if (applicationIcon != null &&
                              applicationName != null)
                            const SizedBox(height: 8),
                          if (applicationName case final name?)
                            Text(
                              name,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                        ],
                      ),
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                destinations: [
                  for (final destination in destinations)
                    NavigationRailDestination(
                      icon: Icon(destination.icon),
                      selectedIcon: Icon(destination.selectedIcon),
                      label: Text(destination.label),
                    ),
                ],
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final overflow = destinations.length > 5;
    final visibleDestinations = overflow
        ? destinations.take(4).toList(growable: false)
        : destinations;
    final compactIndex = overflow && selectedIndex >= 4 ? 4 : selectedIndex;
    return Scaffold(
      body: ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: SafeArea(bottom: true, child: body),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: NavigationBar(
          key: const ValueKey('compact-navigation'),
          selectedIndex: compactIndex,
          onDestinationSelected: (index) {
            if (!overflow || index < 4) {
              onDestinationSelected(index);
              return;
            }
            _showOverflowDestinations(context);
          },
          destinations: [
            for (final destination in visibleDestinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              ),
            if (overflow)
              const NavigationDestination(
                icon: Icon(Icons.more_horiz_rounded),
                selectedIcon: Icon(Icons.more_rounded),
                label: '更多',
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showOverflowDestinations(BuildContext context) async {
    final index = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            for (var index = 4; index < destinations.length; index++)
              ListTile(
                selected: index == selectedIndex,
                leading: Icon(
                  index == selectedIndex
                      ? destinations[index].selectedIcon
                      : destinations[index].icon,
                ),
                title: Text(destinations[index].label),
                trailing: index == selectedIndex
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(context).pop(index),
              ),
          ],
        ),
      ),
    );
    if (index != null) onDestinationSelected(index);
  }
}
