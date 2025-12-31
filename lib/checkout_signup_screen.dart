import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:firebase_auth/firebase_auth.dart';

class CheckoutSignupScreen extends StatefulWidget {
  const CheckoutSignupScreen({super.key});

  @override
  State<CheckoutSignupScreen> createState() => _CheckoutSignupScreenState();
}

class _CheckoutSignupScreenState extends State<CheckoutSignupScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;

  static final bool _firebaseAuthSupported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signUpOrLink() async {
    if (!_firebaseAuthSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('อุปกรณ์นี้ไม่รองรับการสมัครสมาชิกตอนนี้'),
        ),
      );
      return;
    }

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรอกอีเมล และรหัสผ่านอย่างน้อย 6 ตัว')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final auth = FirebaseAuth.instance;
      final currentUser = auth.currentUser;

      if (currentUser != null && currentUser.isAnonymous) {
        // Upgrade anonymous user -> real account, keeps the same UID.
        final cred = EmailAuthProvider.credential(
          email: email,
          password: password,
        );
        await currentUser.linkWithCredential(cred);
      } else {
        // Normal sign-up (creates a new UID).
        await auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'email-already-in-use' => 'อีเมลนี้ถูกใช้งานแล้ว',
        'invalid-email' => 'รูปแบบอีเมลไม่ถูกต้อง',
        'weak-password' => 'รหัสผ่านอ่อนเกินไป',
        _ => e.message ?? 'สมัครสมาชิกไม่สำเร็จ',
      };
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('สมัครสมาชิกไม่สำเร็จ')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('สมัครสมาชิกก่อนชำระเงิน')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'เพื่อสร้าง UID และตู้เซฟส่วนตัว\nกรุณาสมัครสมาชิกก่อนชำระเงิน',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'อีเมล',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'รหัสผ่าน',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _busy ? null : _signUpOrLink,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'สมัครสมาชิก',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
