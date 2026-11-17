import 'package:flutter/material.dart';

/// Lets code without a [BuildContext] (e.g. a session that just expired)
/// navigate and show messages.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
