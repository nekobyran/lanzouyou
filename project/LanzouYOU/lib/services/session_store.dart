import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStore {
  Future<String?> readCookie();

  Future<void> writeCookie(String cookie);

  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore();

  static const _cookieKey = 'provider_session_cookie';
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> readCookie() => _storage.read(key: _cookieKey);

  @override
  Future<void> writeCookie(String cookie) =>
      _storage.write(key: _cookieKey, value: cookie);

  @override
  Future<void> clear() => _storage.delete(key: _cookieKey);
}
