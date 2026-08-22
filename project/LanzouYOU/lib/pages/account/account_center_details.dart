import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/cloud_item.dart';
import '../../shared/app_motion.dart';

class OfficialPortalRequest {
  const OfficialPortalRequest({
    required this.uri,
    required this.title,
    required this.description,
    this.payment = false,
    this.dangerous = false,
  });

  final Uri uri;
  final String title;
  final String description;
  final bool payment;
  final bool dangerous;
}

typedef OfficialPortalOpener =
    Future<void> Function(OfficialPortalRequest request);

class AccountOverviewDetail extends StatelessWidget {
  const AccountOverviewDetail({
    required this.capabilities,
    required this.refreshing,
    required this.onRefresh,
    this.showHeading = true,
    super.key,
  });

  final AccountCapabilities capabilities;
  final bool refreshing;
  final Future<void> Function() onRefresh;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    return _DetailList(
      contentKey: const Key('account-overview-detail'),
      children: [
        if (showHeading)
          _DetailHeading(
            title: '账号概览',
            trailing: IconButton(
              tooltip: '刷新账号与会员状态',
              onPressed: refreshing ? null : () => unawaited(onRefresh()),
              icon: refreshing
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ),
        MembershipSummaryCard(profile: capabilities.membershipProfile),
        const _SectionLabel('账号事实'),
        if (capabilities.facts.isEmpty)
          const ListTile(
            leading: Icon(Icons.help_outline_rounded),
            title: Text('暂无可验证的账号事实'),
            subtitle: Text('刷新后仍未取得的字段不会由应用猜测。'),
          )
        else
          for (var index = 0; index < capabilities.facts.length; index++) ...[
            if (index > 0) const Divider(height: 1),
            _AccountFactTile(fact: capabilities.facts[index]),
          ],
      ],
    );
  }
}

class MembershipSummaryCard extends StatelessWidget {
  const MembershipSummaryCard({required this.profile, super.key});

  final MembershipProfile profile;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, title, stateText, stateKey) = switch (profile.state) {
      MembershipState.vip => (
        Icons.workspace_premium_rounded,
        profile.level?.trim().isNotEmpty == true
            ? profile.level!.trim()
            : 'VIP（等级未知）',
        profile.expiresAt == null
            ? '有效期未知'
            : '有效期至 ${_formatDate(profile.expiresAt!)}',
        const Key('membership-state-vip'),
      ),
      MembershipState.free => (
        Icons.account_circle_outlined,
        '免费用户',
        '当前未开通会员',
        const Key('membership-state-free'),
      ),
      MembershipState.unknown => (
        Icons.help_outline_rounded,
        '会员状态未知',
        profile.reason.trim().isEmpty ? '官方页面未返回可验证状态' : profile.reason,
        const Key('membership-state-unknown'),
      ),
    };
    return Card(
      key: const Key('membership-summary-card'),
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(icon, size: 36, color: colors.onPrimaryContainer),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 180, maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    key: stateKey,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    profile.displayName.trim().isEmpty
                        ? '蓝奏账号'
                        : profile.displayName,
                    style: TextStyle(color: colors.onPrimaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    stateText,
                    style: TextStyle(color: colors.onPrimaryContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MembershipRechargeDetail extends StatefulWidget {
  const MembershipRechargeDetail({
    required this.capabilities,
    required this.openPortal,
    this.showHeading = true,
    super.key,
  });

  final AccountCapabilities capabilities;
  final OfficialPortalOpener openPortal;
  final bool showHeading;

  @override
  State<MembershipRechargeDetail> createState() =>
      _MembershipRechargeDetailState();
}

class _MembershipRechargeDetailState extends State<MembershipRechargeDetail> {
  String? _selectedPlanId;

  MembershipPlan? get _selectedPlan {
    for (final plan in widget.capabilities.plans) {
      if (plan.id == _selectedPlanId) return plan;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final plans = widget.capabilities.plans;
    final selectedPlan = _selectedPlan;
    final paymentBoundarySafe = !widget.capabilities.acceptsPaymentData;
    return _DetailList(
      contentKey: const Key('membership-recharge-detail'),
      children: [
        if (widget.showHeading) const _DetailHeading(title: '会员充值'),
        MembershipSummaryCard(profile: widget.capabilities.membershipProfile),
        const _SectionLabel('套餐与权益'),
        if (plans.isEmpty)
          const ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('暂无可验证的会员套餐'),
            subtitle: Text('应用不会猜测价格或套餐内容，请稍后刷新账号状态。'),
          )
        else
          RadioGroup<String>(
            groupValue: _selectedPlanId,
            onChanged: (value) => setState(() => _selectedPlanId = value),
            child: Column(
              children: [
                for (var index = 0; index < plans.length; index++) ...[
                  if (index > 0) const Divider(height: 1),
                  RadioListTile<String>(
                    key: Key('membership-plan-${plans[index].id}'),
                    value: plans[index].id,
                    enabled: plans[index].available,
                    title: Text(plans[index].label),
                    subtitle: Text(
                      [
                        if (plans[index].priceLabel?.trim().isNotEmpty == true)
                          plans[index].priceLabel!.trim(),
                        plans[index].detail,
                        if (!plans[index].available) '当前不可选',
                      ].join(' · '),
                    ),
                  ),
                ],
              ],
            ),
          ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(
            paymentBoundarySafe
                ? Icons.shield_outlined
                : Icons.gpp_bad_outlined,
          ),
          title: Text(paymentBoundarySafe ? '付款安全' : '已阻止不安全的付款请求'),
          subtitle: Text(
            paymentBoundarySafe
                ? '此页面只选择套餐，不读取、保存或提交任何付款资料。最终购买和付款确认仅在蓝奏云官方页面完成。'
                : '账号能力异常地要求付款资料，应用已禁用继续操作。',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: FilledButton.icon(
            key: const Key('continue-membership-purchase'),
            onPressed:
                selectedPlan == null ||
                    !selectedPlan.available ||
                    !paymentBoundarySafe
                ? null
                : () => unawaited(
                    widget.openPortal(
                      OfficialPortalRequest(
                        uri: widget.capabilities.membershipPortalUrl,
                        title: '前往蓝奏云官方会员页面？',
                        description:
                            '已选择“${selectedPlan.label}”。将使用外部浏览器打开蓝奏云官方页面；应用不会自动购买，也不会读取或提交付款资料。',
                        payment: true,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('确认套餐并前往官方页面'),
          ),
        ),
      ],
    );
  }
}

class PersonalizationSettingsDetail extends StatelessWidget {
  const PersonalizationSettingsDetail({
    required this.capabilities,
    required this.openPortal,
    this.showHeading = true,
    super.key,
  });

  final AccountCapabilities capabilities;
  final OfficialPortalOpener openPortal;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final settings = capabilities.personalization;
    return _DetailList(
      contentKey: const Key('personalization-settings-detail'),
      children: [
        if (showHeading) const _DetailHeading(title: '会员个性化'),
        const ListTile(
          leading: Icon(Icons.info_outline_rounded),
          title: Text('真实状态与只读边界'),
          subtitle: Text('仅显示官方会话返回的当前值。未验证写入的项目不会提供开关或假成功提示。'),
        ),
        _SectionLabel('个性化项目（${settings.length} 项）'),
        if (settings.isEmpty)
          const ListTile(
            leading: Icon(Icons.help_outline_rounded),
            title: Text('暂无可验证的个性化项目'),
            subtitle: Text('刷新后仍未取得的项目不会由应用补造状态。'),
          )
        else
          for (var index = 0; index < settings.length; index++) ...[
            if (index > 0) const Divider(height: 1),
            ListTile(
              key: Key('personalization-${settings[index].id}'),
              leading: Icon(_personalizationIcon(settings[index].id)),
              title: Text(settings[index].title),
              subtitle: Text(_personalizationSummary(settings[index])),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () =>
                  _openPersonalizationItem(context, setting: settings[index]),
            ),
          ],
      ],
    );
  }

  Future<void> _openPersonalizationItem(
    BuildContext context, {
    required PersonalizationSetting setting,
  }) {
    return Navigator.of(context).push<void>(
      _nativeAccountRoute(
        context,
        title: setting.title,
        child: PersonalizationItemDetail(
          setting: setting,
          portalUrl: capabilities.personalizationPortalUrl,
          openPortal: openPortal,
          showHeading: false,
        ),
      ),
    );
  }
}

class PersonalizationItemDetail extends StatelessWidget {
  const PersonalizationItemDetail({
    required this.setting,
    required this.portalUrl,
    required this.openPortal,
    this.showHeading = true,
    super.key,
  });

  final PersonalizationSetting setting;
  final Uri portalUrl;
  final OfficialPortalOpener openPortal;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    return _DetailList(
      contentKey: Key('personalization-detail-${setting.id}'),
      children: [
        if (showHeading) _DetailHeading(title: setting.title),
        ListTile(
          leading: Icon(_personalizationIcon(setting.id)),
          title: const Text('功能'),
          subtitle: Text(setting.description),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('当前值'),
          subtitle: Text(_personalizationValue(setting)),
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(
            setting.writable ? Icons.edit_outlined : Icons.lock_outline_rounded,
          ),
          title: Text(setting.writable ? '官方页面可编辑' : '应用内只读'),
          subtitle: Text(
            setting.reason.trim().isEmpty
                ? setting.writable
                      ? '需要在蓝奏云官方页面完成最终操作。'
                      : '未取得经过验证的写入能力。'
                : setting.reason,
          ),
        ),
        if (setting.available)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: FilledButton.tonalIcon(
              key: Key('open-personalization-official-${setting.id}'),
              onPressed: () => unawaited(
                openPortal(
                  OfficialPortalRequest(
                    uri: portalUrl,
                    title: '前往蓝奏云官方个性化页面？',
                    description:
                        '“${setting.title}”的最终更改将在外部蓝奏云官方页面完成，应用不会伪造或自动提交设置。',
                  ),
                ),
              ),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('前往官方页面完成操作'),
            ),
          ),
      ],
    );
  }
}

class AccountEntryDetail extends StatelessWidget {
  const AccountEntryDetail({
    required this.entry,
    required this.facts,
    required this.openPortal,
    this.showHeading = true,
    super.key,
  });

  final AccountEntry entry;
  final List<AccountFact> facts;
  final OfficialPortalOpener openPortal;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final payment = _isPaymentEntry(entry.id);
    return _DetailList(
      contentKey: Key('account-entry-detail-${entry.id}'),
      children: [
        if (showHeading) _DetailHeading(title: entry.title),
        ListTile(
          leading: Icon(
            entry.available
                ? Icons.check_circle_outline_rounded
                : Icons.block_outlined,
            color: entry.available ? colors.primary : colors.error,
          ),
          title: Text(entry.available ? '当前入口可用' : '当前入口不可用'),
          subtitle: Text(entry.description),
        ),
        if (facts.isNotEmpty) ...[
          const _SectionLabel('账号事实'),
          for (var index = 0; index < facts.length; index++) ...[
            if (index > 0) const Divider(height: 1),
            _AccountFactTile(fact: facts[index]),
          ],
        ],
        if (entry.available)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: FilledButton.icon(
              key: Key('open-account-entry-${entry.id}'),
              style: entry.dangerous
                  ? FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    )
                  : null,
              onPressed: () => unawaited(
                openPortal(
                  OfficialPortalRequest(
                    uri: entry.portalUrl,
                    title: entry.dangerous
                        ? '确认前往官方${entry.title}页面？'
                        : '前往蓝奏云官方${entry.title}页面？',
                    description: entry.dangerous
                        ? '这是敏感且可能不可逆的账号操作。应用不会自动执行“${entry.title}”，请仅在蓝奏云官方页面核对并再次确认。'
                        : payment
                        ? '这是付款或资金相关操作。应用不会读取或提交付款资料，也不会自动付款；请在蓝奏云官方页面核对并最终确认。'
                        : entry.requiresOfficialConfirmation
                        ? '该操作需要在外部蓝奏云官方页面核对并最终确认，应用不会自动提交。'
                        : '将使用外部浏览器打开蓝奏云官方页面。',
                    payment: payment,
                    dangerous: entry.dangerous,
                  ),
                ),
              ),
              icon: Icon(
                entry.dangerous
                    ? Icons.warning_amber_rounded
                    : Icons.open_in_new_rounded,
              ),
              label: Text(entry.dangerous ? '了解风险并继续' : '前往官方页面继续'),
            ),
          ),
      ],
    );
  }
}

class _AccountFactTile extends StatelessWidget {
  const _AccountFactTile({required this.fact});

  final AccountFact fact;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        fact.known ? Icons.check_circle_outline_rounded : Icons.help_outline,
      ),
      title: Text(fact.label),
      subtitle: Text(
        fact.known && fact.value?.trim().isNotEmpty == true
            ? fact.value!.trim()
            : '未知（官方页面未返回可验证值）',
      ),
    );
  }
}

class _DetailList extends StatelessWidget {
  const _DetailList({required this.children, this.contentKey});

  final List<Widget> children;
  final Key? contentKey;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Scrollbar(
        child: ListView(
          key: contentKey,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeading extends StatelessWidget {
  const _DetailHeading({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
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

Route<void> _nativeAccountRoute(
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
        AppMotion.transition(AppMotionTransition.fadeThrough, child, animation),
  );
}

String _formatDate(DateTime date) {
  final local = date.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _personalizationSummary(PersonalizationSetting setting) {
  final availability = setting.available ? '可用' : '不可用';
  final access = setting.writable ? '官方页面可编辑' : '只读';
  return '$availability · $access · ${_personalizationValue(setting)}';
}

String _personalizationValue(PersonalizationSetting setting) {
  if (setting.value?.trim().isNotEmpty == true) return setting.value!.trim();
  if (setting.enabled != null) return setting.enabled! ? '已开启' : '已关闭';
  return '当前值未知';
}

IconData _personalizationIcon(String id) {
  return switch (id) {
    'adFreeDownloads' => Icons.ad_units_outlined,
    'uploadTimeVisibility' => Icons.schedule_outlined,
    'subfolders' => Icons.account_tree_outlined,
    'search' => Icons.manage_search_outlined,
    'defaultFilePassword' => Icons.password_outlined,
    'avatarUpload' => Icons.account_box_outlined,
    'downloadPageTemplate' => Icons.web_outlined,
    'publisherNickname' => Icons.badge_outlined,
    'dailyDownloadReport' => Icons.assessment_outlined,
    'fileRetention' => Icons.event_available_outlined,
    'directLinkDomain' => Icons.language_outlined,
    _ => Icons.tune_outlined,
  };
}

bool _isPaymentEntry(String id) {
  return id == 'balance' || id == 'fileUpgrade';
}
