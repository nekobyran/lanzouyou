import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../pages/login/login_page.dart';

class AccountMenuButton extends StatefulWidget {
  const AccountMenuButton({required this.controller, super.key});

  final AppController controller;

  @override
  State<AccountMenuButton> createState() => _AccountMenuButtonState();
}

class _AccountMenuButtonState extends State<AccountMenuButton> {
  final MenuController _menuController = MenuController();

  Future<void> _openLogin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => LoginPage(controller: widget.controller),
      ),
    );
  }

  void _activate(String accountId) {
    _menuController.close();
    unawaited(widget.controller.switchAccount(accountId));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final active = widget.controller.activeAccount;
        final signedIn = widget.controller.isSignedIn;
        final busy =
            widget.controller.sessionStatus == SessionStatus.authenticating;
        return MenuAnchor(
          controller: _menuController,
          menuChildren: <Widget>[
            if (widget.controller.accounts.isEmpty)
              const MenuItemButton(
                leadingIcon: Icon(Icons.person_off_outlined),
                child: Text('还没有已保存账号'),
              )
            else
              for (final account in widget.controller.accounts)
                MenuItemButton(
                  onPressed: busy ? null : () => _activate(account.id),
                  leadingIcon: const CircleAvatar(
                    radius: 12,
                    child: Icon(Icons.person_rounded, size: 16),
                  ),
                  child: SizedBox(
                    width: 196,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            account.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (account.id == widget.controller.activeAccountId)
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Icon(Icons.check_rounded, size: 18),
                          ),
                      ],
                    ),
                  ),
                ),
            const Divider(height: 1),
            MenuItemButton(
              onPressed: busy
                  ? null
                  : () {
                      _menuController.close();
                      unawaited(_openLogin());
                    },
              leadingIcon: const Icon(Icons.person_add_alt_1_outlined),
              child: const Text('添加账号'),
            ),
            if (signedIn)
              MenuItemButton(
                onPressed: busy
                    ? null
                    : () {
                        _menuController.close();
                        unawaited(widget.controller.logout());
                      },
                leadingIcon: const Icon(Icons.logout_rounded),
                child: const Text('退出当前账号'),
              ),
            if (widget.controller.accounts.length > 1)
              MenuItemButton(
                onPressed: busy
                    ? null
                    : () {
                        _menuController.close();
                        unawaited(widget.controller.logoutAll());
                      },
                leadingIcon: const Icon(Icons.logout_outlined),
                child: const Text('退出全部账号'),
              ),
          ],
          builder: (context, controller, child) {
            final tooltip = signedIn
                ? active?.displayName ?? '账号'
                : busy
                ? '正在登录'
                : '登录账号';
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: busy ? null : controller.open,
              child: IconButton(
                key: const Key('account-menu-button'),
                tooltip: '$tooltip（长按切换账号）',
                onPressed: busy
                    ? null
                    : signedIn
                    ? controller.open
                    : _openLogin,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : CircleAvatar(
                        radius: 16,
                        child: Icon(
                          signedIn
                              ? Icons.person_rounded
                              : Icons.person_outline_rounded,
                          size: 20,
                        ),
                      ),
              ),
            );
          },
        );
      },
    );
  }
}
