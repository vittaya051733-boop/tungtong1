import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
  final TextEditingController _codeController = TextEditingController();

  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  @override
  void initState() {
    super.initState();
    // Auto-send code when screen opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_resend());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
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
      final call = _functions.httpsCallable('sendEmailVerificationCode');
      await call.call(<String, dynamic>{});
      _startResendCooldown();
      _showSnack('ส่งรหัสยืนยันไปที่อีเมลแล้ว');
    } on FirebaseFunctionsException catch (e) {
      _showSnack(e.message ?? 'ส่งรหัสยืนยันไม่สำเร็จ');
    } catch (_) {
      _showSnack('ส่งรหัสยืนยันไม่สำเร็จ');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_busy) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('ไม่พบผู้ใช้');
      return;
    }

    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showSnack('กรุณากรอกรหัส 6 หลัก');
      return;
    }

    setState(() => _busy = true);
    try {
      final call = _functions.httpsCallable('verifyEmailVerificationCode');
      await call.call(<String, dynamic>{'code': code});

      // Refresh auth state.
      await user.reload();
      final refreshed = FirebaseAuth.instance.currentUser;
      if (refreshed?.emailVerified == true) {
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }
      _showSnack('ยืนยันสำเร็จแล้ว แต่สถานะยังไม่อัปเดต ลองใหม่อีกครั้ง');
    } on FirebaseFunctionsException catch (e) {
      _showSnack(e.message ?? 'ยืนยันไม่สำเร็จ');
    } catch (_) {
      _showSnack('ยืนยันไม่สำเร็จ');
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
                'สมัครใช้งานสำเร็จแล้ว\nกรุณากรอกรหัส 6 หลักที่ส่งไปทางอีเมล',
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
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'รหัส 6 หลัก',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => unawaited(_verifyCode()),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _busy ? null : _verifyCode,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'ยืนยันด้วยรหัส',
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
