import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/app_controller.dart';
import '../../models/cloud_item.dart';
import '../../shared/app_motion.dart';
import '../account/account_center_details.dart';

typedef OfficialUrlLauncher = Future<bool> Function(Uri uri);

class AccountSettingsPage extends StatelessWidget {
  const AccountSettingsPage({
    required this.controller,
    this.launchOfficialUrl,
    super.key,
  });

  final AppController controller;
  final OfficialUrlLauncher? launchOfficialUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号与会员')),
      body: SafeArea(
        top: false,
        child: AccountSettingsContent(
          controller: controller,
          launchOfficialUrl: launchOfficialUrl,
        ),
      ),
    );
  }
}

/// Embeddable account surface for the wider Lanzou settings detail pane.
class AccountSettingsContent extends StatefulWidget {
  const AccountSettingsContent({
    required this.controller,
    this.launchOfficialUrl,
    super.key,
  });

  final AppController controller;
  final OfficialUrlLauncher? launchOfficialUrl;

  @override
  State<AccountSettingsContent> createState() => _AccountSettingsContentState();
}

class _AccountSettingsContentState extends State<AccountSettingsContent> {
  static const _wideBreakpoint = 820.0;
  _AccountDestination _selected = const _AccountDestination.overview();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = widget.controller;
      if (controller.sessionStatus == SessionStatus.signedIn &&
          controller.currentAccountCapabilities == null &&
          controller.accountCapabilitiesError == null &&
          !controller.accountCapabilitiesLoading) {
        unawaited(controller.refreshAccountCapabilities());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return AppMotionSwitcher(
          transition: AppMotionTransition.fade,
          child: switch ((
            controller.accountCapabilitiesLoading,
            controller.currentAccountCapabilities,
            controller.accountCapabilitiesError,
          )) {
            (true, null, _) => const _CapabilitiesLoading(
              key: ValueKey('account-capabilities-loading'),
            ),
            (_, null, final String error) => _CapabilitiesError(
              key: const ValueKey('account-capabilities-error-state'),
              message: error,
              retry: controller.refreshAccountCapabilities,
            ),
            (_, final AccountCapabilities capabilities, _) =>
              _CapabilitiesContent(
                key: const ValueKey('account-capabilities-content-state'),
                capabilities: capabilities,
                refreshing: controller.accountCapabilitiesLoading,
                refresh: controller.refreshAccountCapabilities,
                selected: _selected,
                select: _selectDestination,
                openPortal: _openPortal,
                wideBreakpoint: _wideBreakpoint,
              ),
            _ => _CapabilitiesError(
              key: const ValueKey('account-capabilities-idle-state'),
              message: '尚未取得账号能力',
              retry: controller.refreshAccountCapabilities,
            ),
          },
        );
      },
    );
  }

  Future<void> _selectDestination(
    _AccountDestination destination, {
    required bool wide,
    required AccountCapabilities capabilities,
  }) async {
    if (wide) {
      setState(() => _selected = destination);
      return;
    }
    await Navigator.of(context).push<void>(
      _accountRoute(
        context,
        title: destination.title,
        child: _buildDetail(destination, capabilities),
      ),
    );
  }

  Widget _buildDetail(
    _AccountDestination destination,
    AccountCapabilities capabilities,
  ) {
    return switch (destination.kind) {
      _DestinationKind.overview => AccountOverviewDetail(
        capabilities: capabilities,
        refreshing: widget.controller.accountCapabilitiesLoading,
        onRefresh: widget.controller.refreshAccountCapabilities,
        showHeading: false,
      ),
      _DestinationKind.membership => MembershipRechargeDetail(
        capabilities: capabilities,
        openPortal: _openPortal,
        showHeading: false,
      ),
      _DestinationKind.personalization => PersonalizationSettingsDetail(
        capabilities: capabilities,
        openPortal: _openPortal,
        showHeading: false,
      ),
      _DestinationKind.entry => AccountEntryDetail(
        entry: destination.entry!,
        facts: destination.entry!.title == '我的权限'
            ? capabilities.facts
            : const <AccountFact>[],
        openPortal: _openPortal,
        showHeading: false,
      ),
    };
  }

  Future<void> _openPortal(OfficialPortalRequest request) async {
    if (!isTrustedAccountPortalUri(request.uri)) {
      _showMessage('已阻止非蓝奏云官方页面');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _OfficialPortalDialog(request: request),
    );
    if (confirmed != true || !mounted) return;
    final launcher = widget.launchOfficialUrl ?? _launchExternally;
    var opened = false;
    try {
      opened = await launcher(request.uri);
    } on Object {
      opened = false;
    }
    if (!mounted) return;
    if (!opened) _showMessage('无法打开蓝奏云官方页面');
  }

  Future<bool> _launchExternally(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Route<void> _accountRoute(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return PageRouteBuilder<void>(
      transitionDuration: AppMotion.mediumFor(context),
      reverseTransitionDuration: AppMotion.fastFor(context),
      pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(top: false, child: child),
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          AppMotion.transition(
            AppMotionTransition.fadeThrough,
            child,
            animation,
          ),
    );
  }
}

class _CapabilitiesLoading extends StatelessWidget {
  const _CapabilitiesLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        liveRegion: true,
        label: '正在读取蓝奏账号能力',
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在读取账号、会员与个性化状态'),
          ],
        ),
      ),
    );
  }
}

class _CapabilitiesError extends StatelessWidget {
  const _CapabilitiesError({
    required this.message,
    required this.retry,
    super.key,
  });

  final String message;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('account-capabilities-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Semantics(
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const Key('retry-account-capabilities'),
                onPressed: () => unawaited(retry()),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapabilitiesContent extends StatelessWidget {
  const _CapabilitiesContent({
    required this.capabilities,
    required this.refreshing,
    required this.refresh,
    required this.selected,
    required this.select,
    required this.openPortal,
    required this.wideBreakpoint,
    super.key,
  });

  final AccountCapabilities capabilities;
  final bool refreshing;
  final Future<void> Function() refresh;
  final _AccountDestination selected;
  final Future<void> Function(
    _AccountDestination destination, {
    required bool wide,
    required AccountCapabilities capabilities,
  })
  select;
  final OfficialPortalOpener openPortal;
  final double wideBreakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideBreakpoint;
        final destinations = <_AccountDestination>[
          const _AccountDestination.overview(),
          const _AccountDestination.membership(),
          const _AccountDestination.personalization(),
          for (final entry in capabilities.entries)
            _AccountDestination.entry(entry),
        ];
        final resolvedSelected = destinations.firstWhere(
          (destination) => destination.id == selected.id,
          orElse: () => destinations.first,
        );
        final master = _AccountMasterList(
          capabilities: capabilities,
          destinations: destinations,
          selected: wide ? resolvedSelected : null,
          compactSummary: wide,
          refreshing: refreshing,
          refresh: refresh,
          onSelect: (destination) => unawaited(
            select(destination, wide: wide, capabilities: capabilities),
          ),
        );
        if (!wide) {
          return KeyedSubtree(
            key: const Key('account-capabilities-content'),
            child: master,
          );
        }
        final masterWidth = (constraints.maxWidth * 0.34).clamp(300.0, 360.0);
        return Row(
          key: const Key('account-wide-master-detail'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: masterWidth, child: master),
            const VerticalDivider(width: 1),
            Expanded(
              child: AppMotionSwitcher(
                alignment: Alignment.topCenter,
                child: KeyedSubtree(
                  key: ValueKey('account-detail-${resolvedSelected.id}'),
                  child: _detailFor(
                    resolvedSelected,
                    capabilities,
                    refreshing,
                    refresh,
                    openPortal,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AccountMasterList extends StatelessWidget {
  const _AccountMasterList({
    required this.capabilities,
    required this.destinations,
    required this.selected,
    required this.compactSummary,
    required this.refreshing,
    required this.refresh,
    required this.onSelect,
  });

  final AccountCapabilities capabilities;
  final List<_AccountDestination> destinations;
  final _AccountDestination? selected;
  final bool compactSummary;
  final bool refreshing;
  final Future<void> Function() refresh;
  final ValueChanged<_AccountDestination> onSelect;

  @override
  Widget build(BuildContext context) {
    final overview = destinations.firstWhere(
      (destination) => destination.kind == _DestinationKind.overview,
    );
    final membership = destinations
        .where(
          (destination) =>
              destination.kind == _DestinationKind.membership ||
              destination.kind == _DestinationKind.personalization,
        )
        .toList(growable: false);
    final entries = destinations
        .where((destination) => destination.kind == _DestinationKind.entry)
        .toList(growable: false);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Scrollbar(
        child: ListView(
          key: const Key('account-center-master-list'),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 20, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '个人中心',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    key: const Key('refresh-account-capabilities'),
                    tooltip: '刷新账号与会员状态',
                    onPressed: refreshing ? null : () => unawaited(refresh()),
                    icon: refreshing
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            if (compactSummary)
              _CompactMembershipSummary(profile: capabilities.membershipProfile)
            else
              MembershipSummaryCard(profile: capabilities.membershipProfile),
            const _SectionLabel('账号'),
            _DestinationTile(
              destination: overview,
              selected: selected?.id == overview.id,
              onTap: () => onSelect(overview),
            ),
            const _SectionLabel('会员'),
            for (var index = 0; index < membership.length; index++) ...[
              if (index > 0) const Divider(height: 1),
              _DestinationTile(
                destination: membership[index],
                selected: selected?.id == membership[index].id,
                onTap: () => onSelect(membership[index]),
              ),
            ],
            const _SectionLabel('官方个人中心入口'),
            if (entries.isEmpty)
              const ListTile(
                leading: Icon(Icons.help_outline_rounded),
                title: Text('暂无可验证入口'),
                subtitle: Text('刷新后仍未取得的入口不会被应用伪造。'),
              )
            else
              for (var index = 0; index < entries.length; index++) ...[
                if (index > 0) const Divider(height: 1),
                _DestinationTile(
                  destination: entries[index],
                  selected: selected?.id == entries[index].id,
                  onTap: () => onSelect(entries[index]),
                ),
              ],
            const Divider(height: 1),
            const ListTile(
              leading: Icon(Icons.security_outlined),
              title: Text('官方最终操作'),
              subtitle: Text('付款、密码、手机号和注销等敏感操作不会在应用内自动执行。'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactMembershipSummary extends StatelessWidget {
  const _CompactMembershipSummary({required this.profile});

  final MembershipProfile profile;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle, icon) = switch (profile.state) {
      MembershipState.vip => (
        profile.level?.trim().isNotEmpty == true
            ? profile.level!.trim()
            : 'VIP（等级未知）',
        profile.expiresAt == null ? '有效期未知' : '会员状态已验证',
        Icons.workspace_premium_rounded,
      ),
      MembershipState.free => (
        '免费用户',
        '当前未开通会员',
        Icons.account_circle_outlined,
      ),
      MembershipState.unknown => (
        '会员状态未知',
        profile.reason.trim().isEmpty ? '未取得可验证状态' : profile.reason,
        Icons.help_outline_rounded,
      ),
    };
    return ListTile(
      key: const Key('membership-compact-summary'),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _AccountDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final entry = destination.entry;
    final enabled = entry?.available ?? true;
    final subtitle = switch (destination.kind) {
      _DestinationKind.overview => '会员状态、等级、有效期与账号事实',
      _DestinationKind.membership => '原生选择套餐与权益，官方页面最终付款',
      _DestinationKind.personalization => '11 项真实状态、当前值与只读能力',
      _DestinationKind.entry => entry!.description,
    };
    return ListTile(
      key: Key('account-destination-${destination.id}'),
      selected: selected,
      leading: Icon(destination.icon),
      title: Text(destination.title),
      subtitle: Text(enabled ? subtitle : '$subtitle · 当前不可用'),
      trailing: Icon(
        entry?.dangerous == true
            ? Icons.warning_amber_rounded
            : Icons.chevron_right_rounded,
        color: entry?.dangerous == true
            ? Theme.of(context).colorScheme.error
            : null,
      ),
      onTap: onTap,
    );
  }
}

enum _DestinationKind { overview, membership, personalization, entry }

class _AccountDestination {
  const _AccountDestination.overview()
    : id = 'overview',
      title = '账号概览',
      icon = Icons.account_circle_outlined,
      kind = _DestinationKind.overview,
      entry = null;

  const _AccountDestination.membership()
    : id = 'membership',
      title = '会员充值',
      icon = Icons.workspace_premium_outlined,
      kind = _DestinationKind.membership,
      entry = null;

  const _AccountDestination.personalization()
    : id = 'personalization',
      title = '会员个性化',
      icon = Icons.tune_outlined,
      kind = _DestinationKind.personalization,
      entry = null;

  _AccountDestination.entry(AccountEntry value)
    : id = 'entry-${value.id}',
      title = value.title,
      icon = _entryIcon(value.id, value.dangerous),
      kind = _DestinationKind.entry,
      entry = value;

  final String id;
  final String title;
  final IconData icon;
  final _DestinationKind kind;
  final AccountEntry? entry;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _OfficialPortalDialog extends StatelessWidget {
  const _OfficialPortalDialog({required this.request});

  final OfficialPortalRequest request;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('official-portal-confirmation'),
      icon: Icon(
        request.dangerous
            ? Icons.warning_amber_rounded
            : request.payment
            ? Icons.workspace_premium_outlined
            : Icons.open_in_new_rounded,
        color: request.dangerous ? Theme.of(context).colorScheme.error : null,
      ),
      title: Text(request.title),
      content: Text(request.description),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-official-portal'),
          style: request.dangerous
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(request.dangerous ? '继续前往官方页面' : '打开官方页面'),
        ),
      ],
    );
  }
}

Widget _detailFor(
  _AccountDestination destination,
  AccountCapabilities capabilities,
  bool refreshing,
  Future<void> Function() refresh,
  OfficialPortalOpener openPortal,
) {
  return switch (destination.kind) {
    _DestinationKind.overview => AccountOverviewDetail(
      capabilities: capabilities,
      refreshing: refreshing,
      onRefresh: refresh,
    ),
    _DestinationKind.membership => MembershipRechargeDetail(
      capabilities: capabilities,
      openPortal: openPortal,
    ),
    _DestinationKind.personalization => PersonalizationSettingsDetail(
      capabilities: capabilities,
      openPortal: openPortal,
    ),
    _DestinationKind.entry => AccountEntryDetail(
      entry: destination.entry!,
      facts: destination.entry!.title == '我的权限'
          ? capabilities.facts
          : const <AccountFact>[],
      openPortal: openPortal,
    ),
  };
}

IconData _entryIcon(String id, bool dangerous) {
  if (dangerous) return Icons.delete_forever_outlined;
  return switch (id) {
    'permissions' => Icons.verified_user_outlined,
    'balance' => Icons.account_balance_wallet_outlined,
    'fileUpgrade' => Icons.upgrade_outlined,
    'downloadCashout' => Icons.currency_yuan_outlined,
    'cashoutRecords' => Icons.receipt_long_outlined,
    'invite' => Icons.person_add_alt_outlined,
    'password' => Icons.password_outlined,
    'phone' => Icons.phone_android_outlined,
    'closeAccount' => Icons.delete_forever_outlined,
    _ => Icons.open_in_new_rounded,
  };
}
