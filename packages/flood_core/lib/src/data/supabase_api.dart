import 'dart:convert';

import '../services/settings_service.dart';

/// One HTTP reply.
class HttpReply {
  const HttpReply(this.status, this.body);
  final int status;
  final String body;
  bool get ok => status >= 200 && status < 300;
}

/// Sends one HTTP request. The Flutter app passes a small function built on
/// the `http` package; tests pass a fake. Throws when there is no connection.
typedef HttpSend = Future<HttpReply> Function(String method, Uri uri,
    {Map<String, String> headers, String? body});

/// Supabase project address and its publishable key (safe to put in the app;
/// row level security decides what it can reach). Never put a secret key here.
class SupabaseConfig {
  const SupabaseConfig({required this.url, required this.publishableKey});
  final String url;
  final String publishableKey;

  bool get isSet => url.trim().isNotEmpty && publishableKey.trim().isNotEmpty;

  Uri uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(url.trim().replaceFirst(RegExp(r'/+$'), ''));
    return base.replace(path: '${base.path}$path', queryParameters: query);
  }
}

/// Thrown when Supabase answers with an error or cannot be reached.
class SupabaseException implements Exception {
  SupabaseException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => 'SupabaseException${status == null ? '' : ' ($status)'}: $message';
}

/// Keeps this phone signed in as an anonymous Supabase user, so each phone
/// has its own id for its alerts. No account or password is needed.
/// The session (tokens) is kept in [store] so the same id is used after a
/// restart. Requires "Allow anonymous sign-ins" in the Supabase dashboard.
class SupabaseAuth {
  SupabaseAuth({required this.config, required this.send, required this.store, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final SupabaseConfig config;
  final HttpSend send;
  final SettingsStore store;
  final DateTime Function() _clock;

  _Session? _session;
  Future<String>? _pending;

  /// The signed-in user id, once [accessToken] has worked.
  String? get userId => _session?.userId;

  /// A valid access token: from memory, from the phone, refreshed, or from a
  /// new anonymous sign-in, in that order. Calls at the same time share one request.
  Future<String> accessToken() => _pending ??= _token().whenComplete(() => _pending = null);

  Future<String> _token() async {
    _session ??= _Session.fromMap(await store.load());
    final s = _session;
    final now = _clock();
    if (s != null && s.expiresAt.isAfter(now.add(const Duration(seconds: 60)))) return s.accessToken;
    if (s != null) {
      final refreshed = await _call('/auth/v1/token', {'refresh_token': s.refreshToken},
          query: {'grant_type': 'refresh_token'}, allowFail: true);
      if (refreshed != null) return _keep(refreshed, now);
    }
    // No session, or the refresh token is no longer valid: sign in again.
    final fresh = await _call('/auth/v1/signup', {'data': <String, Object?>{}});
    return _keep(fresh!, now);
  }

  Future<String> _keep(Map<String, dynamic> j, DateTime now) async {
    final token = j['access_token'], refresh = j['refresh_token'], user = j['user'];
    final expiresIn = j['expires_in'];
    if (token is! String || refresh is! String || user is! Map || expiresIn is! num) {
      throw SupabaseException('Unexpected sign-in reply');
    }
    final s = _Session('${user['id']}', token, refresh, now.add(Duration(seconds: expiresIn.toInt())));
    _session = s;
    try {
      await store.save(s.toMap());
    } catch (_) {
      // Keeping the session is a bonus: a full phone must not stop the request.
    }
    return token;
  }

  Future<Map<String, dynamic>?> _call(String path, Map<String, Object?> body,
      {Map<String, String>? query, bool allowFail = false}) async {
    final HttpReply r;
    try {
      r = await send('POST', config.uri(path, query),
          headers: {'apikey': config.publishableKey, 'Content-Type': 'application/json'},
          body: jsonEncode(body));
    } catch (_) {
      throw SupabaseException('Could not reach the server');
    }
    if (!r.ok) {
      if (allowFail && r.status >= 400 && r.status < 500) return null;
      throw SupabaseException(_message(r.body, 'Sign-in failed'), status: r.status);
    }
    final j = _decode(r.body);
    if (j is! Map<String, dynamic>) throw SupabaseException('Unexpected sign-in reply');
    return j;
  }

  /// Forgets the session (e.g. after the server says it is no longer valid).
  Future<void> forget() async {
    _session = null;
    try {
      await store.save({});
    } catch (_) {}
  }
}

class _Session {
  _Session(this.userId, this.accessToken, this.refreshToken, this.expiresAt);
  final String userId;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  Map<String, String> toMap() => {
        'user': userId,
        'access': accessToken,
        'refresh': refreshToken,
        'expires': expiresAt.toUtc().toIso8601String(),
      };

  static _Session? fromMap(Map<String, String> m) {
    final u = m['user'], a = m['access'], r = m['refresh'], e = DateTime.tryParse(m['expires'] ?? '');
    if (u == null || a == null || r == null || e == null) return null;
    return _Session(u, a, r, e);
  }
}

/// Small Supabase client: public reads, database functions (RPC) and Edge
/// Functions. Only what the app needs; no extra packages.
class SupabaseApi {
  SupabaseApi({required this.config, required this.send, this.auth});
  final SupabaseConfig config;
  final HttpSend send;

  /// Needed for [rpc] and [function]; public [select] works without it.
  final SupabaseAuth? auth;

  Map<String, String> get _publicHeaders => {
        'apikey': config.publishableKey,
        'Accept': 'application/json',
      };

  Future<Map<String, String>> _userHeaders() async {
    final a = auth;
    if (a == null) throw SupabaseException('Not signed in');
    return {..._publicHeaders, 'Authorization': 'Bearer ${await a.accessToken()}', 'Content-Type': 'application/json'};
  }

  /// Reads rows from a table or view the public may read, e.g.
  /// select('jps_latest', {'select': '*'}).
  Future<List<Map<String, dynamic>>> select(String table, Map<String, String> query) async {
    final r = await _send('GET', config.uri('/rest/v1/$table', query), _publicHeaders, null);
    final j = _decode(r.body);
    if (j is! List) throw SupabaseException('Unexpected reply from $table');
    return [for (final row in j) if (row is Map<String, dynamic>) row];
  }

  /// Calls a database function as the signed-in phone. Returns its JSON result.
  Future<Object?> rpc(String name, Map<String, Object?> args) async {
    final r = await _withUser((h) => _send('POST', config.uri('/rest/v1/rpc/$name'), h, jsonEncode(args)));
    return r.body.trim().isEmpty ? null : _decode(r.body);
  }

  /// Calls an Edge Function as the signed-in phone. Returns the reply as it
  /// came (the caller checks the status).
  Future<HttpReply> function(String name, Map<String, Object?> body) async {
    final h = await _userHeaders();
    try {
      final r = await send('POST', config.uri('/functions/v1/$name'), headers: h, body: jsonEncode(body));
      if (r.status == 401) await auth!.forget();
      return r;
    } catch (_) {
      throw SupabaseException('Could not reach the server');
    }
  }

  /// Runs [call] with the user's token; if the server rejects the token,
  /// signs in again once and retries.
  Future<HttpReply> _withUser(Future<HttpReply> Function(Map<String, String>) call) async {
    try {
      return await call(await _userHeaders());
    } on SupabaseException catch (e) {
      if (e.status != 401) rethrow;
      await auth!.forget();
      return call(await _userHeaders());
    }
  }

  Future<HttpReply> _send(String method, Uri uri, Map<String, String> headers, String? body) async {
    final HttpReply r;
    try {
      r = await send(method, uri, headers: headers, body: body);
    } catch (_) {
      throw SupabaseException('Could not reach the server');
    }
    if (!r.ok) throw SupabaseException(_message(r.body, 'Server error'), status: r.status);
    return r;
  }
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    throw SupabaseException('Unexpected reply');
  }
}

String _message(String body, String fallback) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      for (final k in ['message', 'msg', 'error_description', 'error']) {
        final v = j[k];
        if (v is String && v.isNotEmpty) return v;
        if (v is Map && v['message'] is String) return v['message'] as String;
      }
    }
  } catch (_) {}
  return fallback;
}
