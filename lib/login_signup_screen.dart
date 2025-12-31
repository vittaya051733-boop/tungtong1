import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:firebase_auth/firebase_auth.dart';

class LoginSignupScreen extends StatefulWidget {
  const LoginSignupScreen({
    super.key,
    this.title = 'เข้าสู่ระบบ / สมัครสมาชิก',
  });

  final String title;

  @override
  State<LoginSignupScreen> createState() => _LoginSignupScreenState();
}

class _LoginSignupScreenState extends State<LoginSignupScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _busy = false;
  bool _isLogin = true;

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

  Future<void> _submit() async {
    if (!_firebaseAuthSupported) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('อุปกรณ์นี้ไม่รองรับการล็อกอินตอนนี้')),
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
      if (_isLogin) {
        await auth.signInWithEmailAndPassword(email: email, password: password);
      } else {
        await auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'user-not-found' => 'ไม่พบบัญชีผู้ใช้นี้',
        'wrong-password' => 'รหัสผ่านไม่ถูกต้อง',
        'invalid-credential' => 'อีเมลหรือรหัสผ่านไม่ถูกต้อง',
        'invalid-email' => 'รูปแบบอีเมลไม่ถูกต้อง',
        'email-already-in-use' => 'อีเมลนี้ถูกใช้งานแล้ว',
        'weak-password' => 'รหัสผ่านอ่อนเกินไป',
        _ =>
          e.message ??
              (_isLogin ? 'เข้าสู่ระบบไม่สำเร็จ' : 'สมัครสมาชิกไม่สำเร็จ'),
      };
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isLogin ? 'เข้าสู่ระบบไม่สำเร็จ' : 'สมัครสมาชิกไม่สำเร็จ',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isLogin
                  ? 'เข้าสู่ระบบเพื่อใช้งานตะกร้า'
                  : 'สมัครสมาชิกเพื่อใช้งานตะกร้า',
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
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _isLogin ? 'เข้าสู่ระบบ' : 'สมัครสมาชิก',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _isLogin = !_isLogin);
                    },
              child: Text(
                _isLogin
                    ? 'ยังไม่มีบัญชี? สมัครสมาชิก'
                    : 'มีบัญชีแล้ว? เข้าสู่ระบบ',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
