import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/app_controller.dart';
import '../../models/cloud_item.dart';
import '../../shared/app_motion.dart';

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
                openPortal: _openPortal,
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

  Future<void> _openPortal(_OfficialPortal portal) async {
    final uri = portal.uri;
    if (!_isTrustedOfficialUri(uri)) {
      _showMessage('已阻止非蓝奏云官方页面');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _OfficialPortalDialog(portal: portal),
    );
    if (confirmed != true || !mounted) return;
    final launcher = widget.launchOfficialUrl ?? _launchExternally;
    var opened = false;
    try {
      opened = await launcher(uri);
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
            Text('正在读取账号与会员能力'),
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
                onPressed: retry,
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
    required this.openPortal,
    super.key,
  });

  final AccountCapabilities capabilities;
  final bool refreshing;
  final Future<void> Function() refresh;
  final Future<void> Function(_OfficialPortal portal) openPortal;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: ListView(
        key: const Key('account-capabilities-content'),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionHeader('账号'),
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('蓝奏账号会话'),
                    subtitle: Text(
                      capabilities.authenticated ? '会话有效' : '会话无效',
                    ),
                    trailing: refreshing
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: '刷新账号能力',
                            onPressed: refresh,
                            icon: const Icon(Icons.refresh),
                          ),
                  ),
                  _FeatureRows(features: capabilities.accountFeatures),
                  const Divider(height: 1),
                  ListTile(
                    key: const Key('open-account-portal'),
                    leading: const Icon(Icons.manage_accounts_outlined),
                    title: const Text('账号与空间管理'),
                    subtitle: const Text('在蓝奏云官方页面查看权限、空间与账号安全'),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () => openPortal(
                      _OfficialPortal.account(capabilities.accountPortalUrl),
                    ),
                  ),
                  const _SectionHeader('会员'),
                  _CapabilityTile(
                    key: const Key('open-membership-portal'),
                    icon: Icons.workspace_premium_outlined,
                    title: '会员与增值服务',
                    capability: capabilities.membership,
                    onTap: capabilities.membership.portalUrl == null
                        ? null
                        : () => openPortal(
                            _OfficialPortal.membership(
                              capabilities.membership.portalUrl!,
                            ),
                          ),
                  ),
                  _FeatureRows(features: capabilities.membership.features),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.payments_outlined),
                    title: const Text('付款安全'),
                    subtitle: const Text(
                      '应用不会读取或提交付款信息；购买、续费与付款确认只在蓝奏云官方页面完成。',
                    ),
                  ),
                  const _SectionHeader('会员个性化'),
                  _CapabilityTile(
                    key: const Key('open-personalization-portal'),
                    icon: Icons.tune_outlined,
                    title: '个性化设置',
                    capability: capabilities.personalization,
                    onTap: capabilities.personalization.portalUrl == null
                        ? null
                        : () => openPortal(
                            _OfficialPortal.personalization(
                              capabilities.personalization.portalUrl!,
                            ),
                          ),
                  ),
                  _FeatureRows(features: capabilities.personalization.features),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityTile extends StatelessWidget {
  const _CapabilityTile({
    required this.icon,
    required this.title,
    required this.capability,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final RemoteCapability capability;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final status = capability.available
        ? capability.reason
        : '当前不可用 · ${capability.reason}';
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(status),
      trailing: onTap == null ? null : const Icon(Icons.open_in_new),
      onTap: onTap,
    );
  }
}

class _FeatureRows extends StatelessWidget {
  const _FeatureRows({required this.features});

  final List<String> features;

  @override
  Widget build(BuildContext context) {
    if (features.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final feature in features)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsetsDirectional.only(
              start: 28,
              end: 20,
            ),
            leading: Icon(
              Icons.check_circle_outline,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(feature),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

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

enum _OfficialPortalKind { account, membership, personalization }

class _OfficialPortal {
  const _OfficialPortal._(this.kind, this.uri);

  const _OfficialPortal.account(Uri uri)
    : this._(_OfficialPortalKind.account, uri);

  const _OfficialPortal.membership(Uri uri)
    : this._(_OfficialPortalKind.membership, uri);

  const _OfficialPortal.personalization(Uri uri)
    : this._(_OfficialPortalKind.personalization, uri);

  final _OfficialPortalKind kind;
  final Uri uri;
}

class _OfficialPortalDialog extends StatelessWidget {
  const _OfficialPortalDialog({required this.portal});

  final _OfficialPortal portal;

  @override
  Widget build(BuildContext context) {
    final membership = portal.kind == _OfficialPortalKind.membership;
    final title = switch (portal.kind) {
      _OfficialPortalKind.account => '前往蓝奏云官方账号页面？',
      _OfficialPortalKind.membership => '前往蓝奏云官方会员页面？',
      _OfficialPortalKind.personalization => '前往蓝奏云官方个性化页面？',
    };
    return AlertDialog(
      key: const Key('official-portal-confirmation'),
      icon: Icon(
        membership ? Icons.workspace_premium_outlined : Icons.open_in_new,
      ),
      title: Text(title),
      content: Text(
        membership
            ? '将使用外部浏览器打开蓝奏云官方页面。应用不会读取或提交付款信息，付款确认只在蓝奏云官方页面完成。'
            : '将使用外部浏览器打开蓝奏云官方页面。页面中的账号操作由你确认。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-official-portal'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('打开官方页面'),
        ),
      ],
    );
  }
}

bool _isTrustedOfficialUri(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort) {
    return false;
  }
  return uri.host == 'pc.woozooo.com' || uri.host == 'accounts.woozooo.com';
}
