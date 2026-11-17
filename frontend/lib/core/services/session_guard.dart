import 'dart:async';

import 'package:http/http.dart' as http;

/// Reports when the server stops accepting the saved login.
///
/// Every request that sends the user's token passes its response to
/// [check]. A 401 means that token is invalid, expired or revoked, or the
/// account no longer exists, so [AuthProvider] signs the user out instead of
/// letting every screen fail with "Invalid token".
///
/// The rejected token is reported, not just the fact of a 401, so a slow
/// request from an old session cannot sign out a newer login.
class SessionGuard {
  SessionGuard._();

  static final StreamController<String> _rejected =
      StreamController<String>.broadcast();

  /// Tokens the server rejected with HTTP 401.
  static Stream<String> get rejectedTokens => _rejected.stream;

  /// Reports [response] if it is a 401 for a request that sent a token.
  ///
  /// The token is taken from [token] or, if omitted, from the request's
  /// `Authorization: Bearer` header.
  static void check(http.BaseResponse response, {String? token}) {
    if (response.statusCode != 401) return;
    final used = token ?? _bearer(response.request?.headers['Authorization']);
    if (used != null && used.isNotEmpty) reportRejected(used);
  }

  /// Reports that the server rejected [token] (e.g. a WebSocket closed
  /// with a policy-violation code during authentication).
  static void reportRejected(String token) {
    if (token.isNotEmpty) _rejected.add(token);
  }

  static String? _bearer(String? header) {
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring('Bearer '.length).trim();
  }
}
