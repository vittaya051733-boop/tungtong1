import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'utils/phone_login.dart';

class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key, this.initialPhone});

  /// Can be Thai local format (0xxxxxxxxx) or E.164 (+66...).
  final String? initialPhone;

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _busy = false;
  bool _codeSent = false;
  String? _verificationId;
  int? _forceResendingToken;

  Timer? _resendTimer;
  int _resendSeconds = 0;

  @override
  void initState() {
    super.initState();
    _phoneController.text = (widget.initialPhone ?? '').trim();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _ensurePasswordLinked() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final hasPasswordProvider = user.providerData.any((p) => p.providerId == 'password');
    if (hasPasswordProvider) return true;

    final phone = user.phoneNumber;
    if (phone == null || phone.isEmpty) {
      _showSnack('ไม่พบเบอร์โทรในบัญชี');
      return false;
    }

    final pseudoEmail = phoneToPseudoEmailFromE164(phone);
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _SetPasswordScreen(pseudoEmail: pseudoEmail),
      ),
    );

    if (ok == true) return true;

    // If user cancels password setup, sign out so the app doesn't look "logged in"
    // while they still can't use phone+password next time.
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Best-effort.
    }
    return false;
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
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

  Future<void> _sendCode({required bool isResend}) async {
    if (_busy) return;
    if (kIsWeb) {
      _showSnack('ยังไม่รองรับ OTP บน Web ในโปรเจคนี้');
      return;
    }

    final e164 = normalizePhoneToE164Thai(_phoneController.text);
    if (e164 == null) {
      _showSnack('กรุณากรอกเบอร์โทรให้ถูกต้อง (เช่น 0812345678 หรือ +66812345678)');
      return;
    }

    setState(() => _busy = true);
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: e164,
        timeout: const Duration(seconds: 60),
        forceResendingToken: isResend ? _forceResendingToken : null,
        verificationCompleted: (credential) async {
          // Auto-retrieval on Android.
          try {
            await FirebaseAuth.instance.signInWithCredential(credential);
            if (!mounted) return;
            final ok = await _ensurePasswordLinked();
            if (!mounted) return;
            if (ok) Navigator.of(context).pop(true);
          } catch (_) {
            // Ignore; user can still input code manually.
          }
        },
        verificationFailed: (e) {
          final msg = switch (e.code) {
            'invalid-phone-number' => 'เบอร์โทรไม่ถูกต้อง',
            'too-many-requests' => 'ขอ OTP บ่อยเกินไป กรุณาลองใหม่ภายหลัง',
            _ => e.message ?? 'ส่ง OTP ไม่สำเร็จ',
          };
          _showSnack(msg);
        },
        codeSent: (verificationId, forceResendingToken) {
          setState(() {
            _codeSent = true;
            _verificationId = verificationId;
            _forceResendingToken = forceResendingToken;
          });
          _startResendCountdown();
          _showSnack('ส่งรหัส OTP แล้ว');
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId = verificationId;
        },
      );
    } on FirebaseAuthException catch (e) {
      _showSnack(e.message ?? 'ส่ง OTP ไม่สำเร็จ');
    } catch (_) {
      _showSnack('ส่ง OTP ไม่สำเร็จ');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_busy) return;
    final vid = _verificationId;
    if (vid == null || vid.isEmpty) {
      _showSnack('ยังไม่ได้ส่ง OTP');
      return;
    }

    final code = _codeController.text.trim();
    if (code.length < 4) {
      _showSnack('กรุณากรอกรหัส OTP');
      return;
    }

    setState(() => _busy = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: vid,
        smsCode: code,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (!mounted) return;
      final ok = await _ensurePasswordLinked();
      if (!mounted) return;
      if (ok) Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'invalid-verification-code' => 'รหัส OTP ไม่ถูกต้อง',
        'session-expired' => 'OTP หมดอายุ กรุณาขอใหม่',
        _ => e.message ?? 'ยืนยัน OTP ไม่สำเร็จ',
      };
      _showSnack(msg);
    } catch (_) {
      _showSnack('ยืนยัน OTP ไม่สำเร็จ');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _codeSent && _resendSeconds == 0 && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('ยืนยันเบอร์โทร (OTP)')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'เบอร์โทร',
                  border: OutlineInputBorder(),
                ),
                enabled: !_busy && !_codeSent,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: (_busy || _codeSent)
                      ? null
                      : () => _sendCode(isResend: false),
                  child: _busy && !_codeSent
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'ส่งรหัส OTP',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              ),
              if (_codeSent) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'รหัส OTP',
                    border: OutlineInputBorder(),
                  ),
                  enabled: !_busy,
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
                            'ยืนยัน OTP',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: canResend ? () => _sendCode(isResend: true) : null,
                  child: Text(
                    _resendSeconds > 0
                        ? 'ขอ OTP ใหม่ได้ใน $_resendSeconds วินาที'
                        : 'ขอ OTP ใหม่',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SetPasswordScreen extends StatefulWidget {
  const _SetPasswordScreen({required this.pseudoEmail});

  final String pseudoEmail;

  @override
  State<_SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<_SetPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _submit() async {
    if (_busy) return;
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (password.length < 6) {
      _showSnack('ตั้งรหัสผ่านอย่างน้อย 6 ตัว');
      return;
    }
    if (password != confirm) {
      _showSnack('รหัสผ่านไม่ตรงกัน');
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showSnack('ไม่พบผู้ใช้');
      return;
    }

    setState(() => _busy = true);
    try {
      final credential = EmailAuthProvider.credential(
        email: widget.pseudoEmail,
        password: password,
      );
      await user.linkWithCredential(credential);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'provider-already-linked' => null,
        'credential-already-in-use' => 'บัญชีนี้ถูกใช้งานแล้ว',
        'email-already-in-use' => 'บัญชีนี้ถูกใช้งานแล้ว',
        'weak-password' => 'รหัสผ่านอ่อนเกินไป',
        _ => e.message ?? 'ตั้งรหัสผ่านไม่สำเร็จ',
      };
      if (msg == null) {
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }
      _showSnack(msg);
    } catch (_) {
      _showSnack('ตั้งรหัสผ่านไม่สำเร็จ');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ตั้งรหัสผ่าน')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ยืนยัน OTP สำเร็จแล้ว\nตั้งรหัสผ่านเพื่อให้ครั้งต่อไปล็อกอินด้วยเบอร์โทร + รหัสผ่านได้เลย',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'รหัสผ่าน',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmController,
                obscureText: true,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'ยืนยันรหัสผ่าน',
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
                      : const Text(
                          'บันทึกรหัสผ่าน',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
