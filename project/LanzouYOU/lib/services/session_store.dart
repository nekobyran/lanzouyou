import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredSessionAccount {
  const StoredSessionAccount({
    required this.id,
    required this.displayName,
    required this.cookie,
  });

  factory StoredSessionAccount.fromJson(Map<String, Object?> json) {
    final id = '${json['id'] ?? ''}'.trim();
    final displayName = '${json['displayName'] ?? ''}'.trim();
    final cookie = '${json['cookie'] ?? ''}'.trim();
    if (id.isEmpty || displayName.isEmpty || cookie.isEmpty) {
      throw const FormatException('登录账号存储数据不完整');
    }
    return StoredSessionAccount(
      id: id,
      displayName: displayName,
      cookie: cookie,
    );
  }

  final String id;
  final String displayName;
  final String cookie;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'displayName': displayName,
    'cookie': cookie,
  };

  StoredSessionAccount copyWith({
    String? id,
    String? displayName,
    String? cookie,
  }) {
    return StoredSessionAccount(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      cookie: cookie ?? this.cookie,
    );
  }
}

class StoredSessionVault {
  const StoredSessionVault({
    this.accounts = const <StoredSessionAccount>[],
    this.activeAccountId,
  });

  factory StoredSessionVault.fromJson(Map<String, Object?> json) {
    final rawAccounts = json['accounts'];
    if (rawAccounts is! List) {
      throw const FormatException('登录账号存储格式无效');
    }
    final accounts = <StoredSessionAccount>[];
    final ids = <String>{};
    for (final raw in rawAccounts) {
      if (raw is! Map) throw const FormatException('登录账号存储格式无效');
      final account = StoredSessionAccount.fromJson(
        raw.cast<String, Object?>(),
      );
      if (ids.add(account.id)) accounts.add(account);
    }
    final active = json['activeAccountId'];
    final activeAccountId = active is String && ids.contains(active)
        ? active
        : accounts.isEmpty
        ? null
        : accounts.first.id;
    return StoredSessionVault(
      accounts: List<StoredSessionAccount>.unmodifiable(accounts),
      activeAccountId: activeAccountId,
    );
  }

  final List<StoredSessionAccount> accounts;
  final String? activeAccountId;

  Map<String, Object?> toJson() => <String, Object?>{
    'activeAccountId': activeAccountId,
    'accounts': accounts.map((account) => account.toJson()).toList(),
  };
}

abstract interface class SessionStore {
  Future<StoredSessionVault> read();

  Future<void> write(StoredSessionVault vault);

  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore();

  static const _vaultKey = 'provider_session_accounts_v2';
  static const _legacyCookieKey = 'provider_session_cookie';
  static const _storage = FlutterSecureStorage();

  @override
  Future<StoredSessionVault> read() async {
    final encoded = await _storage.read(key: _vaultKey);
    if (encoded != null && encoded.trim().isNotEmpty) {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw const FormatException('登录账号存储格式无效');
      }
      return StoredSessionVault.fromJson(decoded.cast<String, Object?>());
    }

    // One-time migration of the actually shipped single-session format.
    final legacyCookie = await _storage.read(key: _legacyCookieKey);
    if (legacyCookie == null || legacyCookie.trim().isEmpty) {
      return const StoredSessionVault();
    }
    return StoredSessionVault(
      accounts: <StoredSessionAccount>[
        StoredSessionAccount(
          id: 'legacy',
          displayName: '已保存账号',
          cookie: legacyCookie.trim(),
        ),
      ],
      activeAccountId: 'legacy',
    );
  }

  @override
  Future<void> write(StoredSessionVault vault) async {
    await _storage.write(key: _vaultKey, value: jsonEncode(vault.toJson()));
    await _storage.delete(key: _legacyCookieKey);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _vaultKey);
    await _storage.delete(key: _legacyCookieKey);
  }
}
