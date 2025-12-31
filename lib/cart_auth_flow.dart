import 'package:flutter/material.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'cart_screen.dart';
import 'login_screen.dart';

/// Opens the cart screen, but requires the user to login/signup first.
///
/// This keeps auth UI separate from any specific feature screen.
Future<void> openCartWithAuth(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user != null && !user.isAnonymous) {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CartScreen()));
    return;
  }

  final ok = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen()));
  if (ok != true || !context.mounted) return;

  await Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const CartScreen()));
}
