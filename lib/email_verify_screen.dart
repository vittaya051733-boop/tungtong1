import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class EmailVerifyScreen extends StatefulWidget {
  const EmailVerifyScreen({super.key, required this.email});

  final String email;

  @override
  State<EmailVerifyScreen> createState() => _EmailVerifyScreenState();
}

class _EmailVerifyScreenState extends State<EmailVerifyScreen> {
  bool _busy = false;
  Timer? _timer;
  int _resendSeconds = 0;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _startResendCooldown() {
    _timer?.cancel();
    setState(() => _resendSeconds = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        t.cancel();
        setState(() => _resendSeconds = 0);
        return;
      }
      setState(() => _resendSeconds -= 1);
    });
  }

  Future<void> _resend() async {
    if (_busy || _resendSeconds > 0) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('ไม่พบผู้ใช้');
      return;
    }

    setState(() => _busy = true);
    try {
      await user.sendEmailVerification();
      _startResendCooldown();
      _showSnack('ส่งอีเมลยืนยันแล้ว');
    } on FirebaseAuthException catch (e) {
      _showSnack(e.message ?? 'ส่งอีเมลยืนยันไม่สำเร็จ');
    } catch (_) {
      _showSnack('ส่งอีเมลยืนยันไม่สำเร็จ');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkVerified() async {
    if (_busy) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('ไม่พบผู้ใช้');
      return;
    }

    setState(() => _busy = true);
    try {
      await user.reload();
      final refreshed = FirebaseAuth.instance.currentUser;
      if (refreshed?.emailVerified == true) {
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }
      _showSnack('ยังไม่ยืนยันอีเมล');
    } catch (_) {
      _showSnack('ตรวจสอบสถานะไม่สำเร็จ');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final resendLabel = _resendSeconds > 0
        ? 'ส่งอีเมลอีกครั้งได้ใน $_resendSeconds วินาที'
        : 'ส่งอีเมลยืนยันอีกครั้ง';

    return Scaffold(
      appBar: AppBar(title: const Text('ยืนยันอีเมล')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'สมัครใช้งานสำเร็จแล้ว\nกรุณายืนยันอีเมลเพื่อเข้าสู่ระบบ',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                widget.email,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _busy ? null : _checkVerified,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'ฉันยืนยันอีเมลแล้ว',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: (_busy || _resendSeconds > 0) ? null : _resend,
                child: Text(
                  resendLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
