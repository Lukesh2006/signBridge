import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/session_guard.dart';

class AuthProvider extends ChangeNotifier {
  String? _userId;
  String? _token;
  String? _email;
  bool _isLoading = false;
  String? _error;
  bool _sessionExpired = false;

  String? get userId => _userId;
  String? get token => _token;
  String? get email => _email;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isLoggedIn => _userId != null && _userId!.isNotEmpty;

  /// True after the server rejected the saved login and the user was signed
  /// out because of it. The app shows the sign-in screen, then calls
  /// [acknowledgeSessionExpired].
  bool get sessionExpired => _sessionExpired;

  late final Future<void> initialization;
  late final StreamSubscription<String> _rejectedTokens;

  AuthProvider() {
    initialization = _loadSession();
    _rejectedTokens = SessionGuard.rejectedTokens.listen(_onTokenRejected);
  }

  Future<void> _onTokenRejected(String rejected) async {
    // Ignore 401s for an older token (e.g. a slow request that finished
    // after the user signed in again).
    if (!isLoggedIn || rejected != _token) return;
    _sessionExpired = true;
    await logout();
  }

  void acknowledgeSessionExpired() {
    if (!_sessionExpired) return;
    _sessionExpired = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _rejectedTokens.cancel();
    super.dispose();
  }

  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('userId');
    _token = prefs.getString('token');
    _email = prefs.getString('email');
    notifyListeners();
  }

  String _formatError(dynamic e, String fallback) {
    if (e is Exception) {
      final msg = e.toString().replaceFirst('Exception: ', '').trim();
      if (msg.isNotEmpty && !msg.contains('SocketException')) {
        return msg;
      }
    }
    return fallback;
  }

  Future<bool> login(String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final authData = await ApiService.login(email, password);
      final userId = authData['id'] ?? '';
      final token = authData['token'] ?? '';
      if (userId.isNotEmpty) {
        _sessionExpired = false;
        _userId = userId;
        _token = token;
        _email = email;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userId', userId);
        if (token.isNotEmpty) await prefs.setString('token', token);
        await prefs.setString('email', email);
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = 'Invalid credentials. Please try again.';
      }
    } catch (e) {
      _error = _formatError(e, 'Connection error. Is the server running?');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> register(String email, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final authData = await ApiService.register(email, password);
      final userId = authData['id'] ?? '';
      final token = authData['token'] ?? '';
      if (userId.isNotEmpty) {
        _sessionExpired = false;
        _userId = userId;
        _token = token;
        _email = email;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userId', userId);
        if (token.isNotEmpty) await prefs.setString('token', token);
        await prefs.setString('email', email);
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        debugPrint(userId);
        _error = 'Registration failed. Email may already be in use.';
      }
    } catch (e) {
      debugPrint(e.toString());
      _error = _formatError(e, 'Connection error. Is the server running?');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> forgotPassword(String email) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final success = await ApiService.forgotPassword(email);
      if (success) {
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = 'Password reset failed.';
      }
    } catch (e) {
      debugPrint(e.toString());
      _error = _formatError(e, 'Connection error. Is the server running?');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    _userId = null;
    _token = null;
    _email = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('userId');
    await prefs.remove('token');
    await prefs.remove('email');
    notifyListeners();
  }
}
