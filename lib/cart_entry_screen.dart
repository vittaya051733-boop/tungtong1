import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'cart_screen.dart';
import 'login_screen.dart';

/// A dedicated route for the bottom "Cart" button.
///
/// This screen owns the auth-gating flow:
/// - If already signed-in (and not anonymous) -> replaces itself with [CartScreen]
/// - Otherwise -> pushes [LoginScreen]; on success replaces itself with [CartScreen]
class CartEntryScreen extends StatefulWidget {
  const CartEntryScreen({super.key});

  @override
  State<CartEntryScreen> createState() => _CartEntryScreenState();
}

class _CartEntryScreenState extends State<CartEntryScreen> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runFlow();
    });
  }

  Future<void> _runFlow() async {
    final nav = Navigator.of(context);
    final user = FirebaseAuth.instance.currentUser;

    if (user != null && !user.isAnonymous) {
      await nav.pushReplacement(
        MaterialPageRoute(builder: (_) => const CartScreen()),
      );
      return;
    }

    final ok = await nav.push<bool>(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );

    if (!mounted) return;

    if (ok == true) {
      await nav.pushReplacement(
        MaterialPageRoute(builder: (_) => const CartScreen()),
      );
    } else {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}
