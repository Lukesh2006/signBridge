import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_bridge/core/app_keys.dart';
import 'package:sign_bridge/core/services/api_service.dart';
import 'package:sign_bridge/core/services/session_guard.dart';
import 'package:sign_bridge/features/auth/providers/auth_provider.dart';
import 'package:sign_bridge/features/auth/screens/login_screen.dart';
import 'package:sign_bridge/main.dart';

http.Response _response(int status, {String? bearer}) {
  final request = http.Request('GET', Uri.parse('https://example.test/me'));
  if (bearer != null) request.headers['Authorization'] = 'Bearer $bearer';
  return http.Response('{}', status, request: request);
}

Future<AuthProvider> _signedIn(String token) async {
  SharedPreferences.setMockInitialValues({
    'userId': 'uid1',
    'token': token,
    'email': 'a@b.com',
  });
  final auth = AuthProvider();
  await auth.initialization;
  return auth;
}

void main() {
  group('SessionGuard.check', () {
    test('reports the token a rejected request sent', () async {
      final reported = <String>[];
      final sub = SessionGuard.rejectedTokens.listen(reported.add);
      SessionGuard.check(_response(401, bearer: 'tok1'));
      SessionGuard.check(_response(401, bearer: 'ignored'), token: 'tok2');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(reported, ['tok1', 'tok2']);
    });

    test('ignores other statuses and 401s that sent no token', () async {
      final reported = <String>[];
      final sub = SessionGuard.rejectedTokens.listen(reported.add);
      SessionGuard.check(_response(200, bearer: 'tok1'));
      SessionGuard.check(_response(403, bearer: 'tok1'));
      SessionGuard.check(_response(401)); // e.g. a failed login
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(reported, isEmpty);
    });
  });

  group('AuthProvider', () {
    test('signs out when the current token is rejected', () async {
      final auth = await _signedIn('tok1');
      SessionGuard.reportRejected('tok1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(auth.isLoggedIn, isFalse);
      expect(auth.token, isNull);
      expect(auth.sessionExpired, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);

      auth.acknowledgeSessionExpired();
      expect(auth.sessionExpired, isFalse);
      auth.dispose();
    });

    test('ignores a rejected token from an older session', () async {
      final auth = await _signedIn('new-token');
      SessionGuard.reportRejected('old-token');
      await Future<void>.delayed(Duration.zero);

      expect(auth.isLoggedIn, isTrue);
      expect(auth.sessionExpired, isFalse);
      auth.dispose();
    });
  });

  test('a 401 from the history API signs the user out', () async {
    dotenv.loadFromString(envString: 'API_BASE_URL=https://example.test');
    final auth = await _signedIn('tok1');
    await expectLater(
      http.runWithClient(
        () => ApiService.getHistory('tok1'),
        () => MockClient(
            (_) async => http.Response('{"error":"Invalid token"}', 401)),
      ),
      throwsException,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(auth.isLoggedIn, isFalse);
    auth.dispose();
  });

  testWidgets('an expired session returns to sign-in with a message',
      (tester) async {
    final auth = await tester.runAsync(() => _signedIn('tok1'));
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: auth!,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: appMessengerKey,
          builder: (context, navigator) =>
              SessionExpiryHandler(child: navigator!),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    expect(find.text('Home'), findsOneWidget);

    await tester.runAsync(() async {
      SessionGuard.reportRejected('tok1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Home'), findsNothing);
    expect(
      find.text('Your session has expired. Please sign in again.'),
      findsOneWidget,
    );
    expect(auth.sessionExpired, isFalse);
    // Login has a repeating background animation; do not pumpAndSettle.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
