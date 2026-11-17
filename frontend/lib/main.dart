import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:sign_bridge/features/auth/providers/auth_provider.dart';
import 'package:sign_bridge/features/translate/providers/translation_provider.dart';
import 'package:sign_bridge/features/splash/screens/splash_screen.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sign_bridge/core/app_keys.dart';
import 'package:sign_bridge/features/auth/screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => TranslationProvider()),
      ],
      child: ScreenUtilInit(
        designSize: const Size(390, 844),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, child) {
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            scaffoldMessengerKey: appMessengerKey,
            builder: (context, navigator) =>
                SessionExpiryHandler(child: navigator ?? const SizedBox.shrink()),
            debugShowCheckedModeBanner: false,
            title: 'SignBridge',
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF2B2D5D),
                brightness: Brightness.light,
              ),
              useMaterial3: true,
              fontFamily: 'Roboto',
            ),
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}

/// Returns to the sign-in screen when the server rejects the saved login.
class SessionExpiryHandler extends StatefulWidget {
  const SessionExpiryHandler({super.key, required this.child});

  final Widget child;

  @override
  State<SessionExpiryHandler> createState() => _SessionExpiryHandlerState();
}

class _SessionExpiryHandlerState extends State<SessionExpiryHandler> {
  AuthProvider? _auth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthProvider>();
    if (identical(auth, _auth)) return;
    _auth?.removeListener(_onAuthChanged);
    _auth = auth..addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    final auth = _auth;
    if (auth == null || !auth.sessionExpired) return;
    auth.acknowledgeSessionExpired();
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
    appMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Your session has expired. Please sign in again.'),
      ));
  }

  @override
  void dispose() {
    _auth?.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}