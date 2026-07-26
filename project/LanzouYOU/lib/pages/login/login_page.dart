import 'package:flutter/material.dart';

import '../../controllers/app_controller.dart';
import '../../shared/app_motion.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    required this.controller,
    this.publicLibraryBuilder,
    super.key,
  });

  final AppController controller;
  final WidgetBuilder? publicLibraryBuilder;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.clear();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await widget.controller.login(
      _accountController.text,
      _passwordController.text,
    );
    _passwordController.clear();
  }

  Future<void> _openPublicLibrary() async {
    final builder = widget.publicLibraryBuilder;
    if (builder == null) return;
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: AppMotion.mediumFor(context),
        reverseTransitionDuration: AppMotion.fastFor(context),
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            AppMotion.transition(
              AppMotionTransition.fadeThrough,
              child,
              animation,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy =
        widget.controller.sessionStatus == SessionStatus.authenticating;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: FocusTraversalGroup(
                    child: AutofillGroup(
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Icon(
                              Icons.cloud_outlined,
                              size: 48,
                              color: Theme.of(context).colorScheme.primary,
                              semanticLabel: 'LanzouYOU',
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '登录 LanzouYOU',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 24),
                            TextFormField(
                              key: const Key('account-field'),
                              controller: _accountController,
                              enabled: !busy,
                              autofillHints: const [AutofillHints.username],
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: '账号',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '请输入账号'
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              key: const Key('password-field'),
                              controller: _passwordController,
                              enabled: !busy,
                              obscureText: _obscurePassword,
                              autofillHints: const [AutofillHints.password],
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => _submit(),
                              decoration: InputDecoration(
                                labelText: '密码',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                                  onPressed: busy
                                      ? null
                                      : () => setState(
                                          () => _obscurePassword =
                                              !_obscurePassword,
                                        ),
                                  icon: AppMotionSwitcher(
                                    transition: AppMotionTransition.fade,
                                    child: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      key: ValueKey(_obscurePassword),
                                    ),
                                  ),
                                ),
                              ),
                              validator: (value) =>
                                  value == null || value.isEmpty
                                  ? '请输入密码'
                                  : null,
                            ),
                            AppMotionAnimatedSize(
                              child: widget.controller.sessionError == null
                                  ? const SizedBox(height: 24)
                                  : Semantics(
                                      liveRegion: true,
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 16),
                                        child: Text(
                                          widget.controller.sessionError!,
                                          key: const Key('login-error'),
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              key: const Key('login-button'),
                              onPressed: busy ? null : _submit,
                              icon: AppMotionSwitcher(
                                transition: AppMotionTransition.fade,
                                child: busy
                                    ? const SizedBox.square(
                                        key: ValueKey('login-progress'),
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.login,
                                        key: ValueKey('login-icon'),
                                      ),
                              ),
                              label: Text(busy ? '正在登录' : '登录'),
                            ),
                            if (widget.publicLibraryBuilder != null) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                key: const Key('browse-public-library'),
                                onPressed: busy ? null : _openPublicLibrary,
                                icon: const Icon(Icons.apps_outlined),
                                label: const Text('免登录浏览软件库'),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(
                              '会话仅保存在系统安全存储中。',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
