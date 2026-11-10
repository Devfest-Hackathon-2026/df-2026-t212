import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'agent.dart';

/// A refresh token is scoped to the Firebase project and never leaves this
/// device except when exchanged with Google's Secure Token service.
abstract class CloudRefreshStore {
  Future<String?> read();
  Future<void> write(String token);
}

class SecureCloudRefreshStore implements CloudRefreshStore {
  const SecureCloudRefreshStore(this.projectId);
  final String projectId;
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  String get _key => 'ai.firebase.refresh.$projectId';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String token) async {
    await _storage.write(key: _key, value: token);
    if (await _storage.read(key: _key) != token) {
      throw AgentError('This device could not save its AI identity. Please try again.');
    }
  }
}

/// Retains one anonymous account. A failed refresh never creates a new one.
class CloudAuth {
  CloudAuth({required this.apiKey, required this.store, http.Client? client,
      DateTime Function()? now})
      : client = client ?? http.Client(), now = now ?? DateTime.now;
  final String apiKey;
  final CloudRefreshStore store;
  final http.Client client;
  final DateTime Function() now;
  String? _token;
  DateTime? _expiresAt;
  Future<String>? _pending;

  Future<String> token({bool forceRefresh = false}) async {
    if (apiKey.isEmpty) {
      throw AgentError('Google Cloud AI is not configured on this app.');
    }
    if (!forceRefresh && _token != null &&
        _expiresAt!.isAfter(now().add(const Duration(minutes: 1)))) {
      return _token!;
    }
    final pending = _pending;
    if (pending != null) return pending;
    final work = _load();
    _pending = work;
    try {
      return await work;
    } finally {
      if (identical(_pending, work)) _pending = null;
    }
  }

  Future<String> _load() async {
    try {
      final refresh = await store.read();
      final response = refresh == null
          ? await client.post(
              Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signUp', {'key': apiKey}),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'returnSecureToken': true}),
            ).timeout(const Duration(seconds: 20))
          : await client.post(
              Uri.https('securetoken.googleapis.com', '/v1/token', {'key': apiKey}),
              body: {'grant_type': 'refresh_token', 'refresh_token': refresh},
            ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw AgentError(refresh == null
            ? 'Could not connect to Google Cloud AI. Please try again.'
            : 'Could not reconnect to Google Cloud AI. Your saved identity has been kept. Please try again.');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final next = (data['refresh_token'] ?? data['refreshToken']) as String;
      final token = (data['id_token'] ?? data['idToken']) as String;
      final seconds = int.parse('${data['expires_in'] ?? data['expiresIn']}');
      if (next.isEmpty || token.isEmpty || seconds <= 0) throw const FormatException();
      // Publish the ID token only after the corresponding identity is durable.
      await store.write(next);
      _token = token;
      _expiresAt = now().add(Duration(seconds: seconds));
      return token;
    } on AgentError {
      rethrow;
    } catch (_) {
      throw AgentError('Could not connect to Google Cloud AI. Check your connection and try again.');
    }
  }
}
