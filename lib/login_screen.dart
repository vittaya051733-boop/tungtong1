import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'utils/app_colors.dart';
import 'phone_auth_screen.dart';
import 'utils/phone_login.dart';
import 'email_verify_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _isSocialLoading = false;
  bool _isPasswordVisible = false;
  bool _isPasswordSaved = false;
  String? _socialLoadingKey;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _isValidEmailFormat(String value) {
    final email = value.trim();
    if (email.isEmpty) return false;
    // Simple, practical email format check.
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
  }

  void _goToAppFirstPage() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<bool> _autoSignupAndVerifyEmail({
    required NavigatorState nav,
    required String email,
    required String password,
  }) async {
    await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await FirebaseAuth.instance.currentUser?.sendEmailVerification();

    if (!mounted) return false;
    final ok = await nav.push<bool>(
      MaterialPageRoute(builder: (_) => EmailVerifyScreen(email: email)),
    );
    if (ok == true) return true;

    // If user cancels verification, sign out to keep state consistent.
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Best-effort.
    }
    return false;
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _showSnack('กรุณากรอกอีเมลก่อน');
      return;
    }
    if (RegExp(r'^\+?[0-9]{9,}$').hasMatch(email)) {
      _showSnack('การรีเซ็ตรหัสผ่านรองรับเฉพาะอีเมล');
      return;
    }
    if (!_isValidEmailFormat(email)) {
      _showSnack('รูปแบบอีเมลไม่ถูกต้อง');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      _showSnack('ส่งลิงก์รีเซ็ตรหัสผ่านไปที่อีเมลแล้ว');
    } on FirebaseAuthException catch (e) {
      _showSnack(e.message ?? 'ส่งลิงก์รีเซ็ตรหัสผ่านไม่สำเร็จ');
    } catch (_) {
      _showSnack('ส่งลิงก์รีเซ็ตรหัสผ่านไม่สำเร็จ');
    }
  }

  Future<void> _signInWithEmail() async {
    final input = _emailController.text.trim();
    final password = _passwordController.text;
    if (input.isEmpty || password.isEmpty) {
      _showSnack('กรอกข้อมูลให้ครบถ้วน');
      return;
    }

    final isPhone = RegExp(r'^\+?[0-9]{9,}$').hasMatch(input);
    if (isPhone) {
      final pseudoEmail = phoneInputToPseudoEmail(input);
      if (pseudoEmail == null) {
        _showSnack('กรุณากรอกเบอร์โทรให้ถูกต้อง');
        return;
      }

      setState(() => _isLoading = true);
      try {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: pseudoEmail,
          password: password,
        );

        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      } on FirebaseAuthException catch (e) {
        if (e.code == 'wrong-password') {
          _showSnack('รหัสผ่านไม่ถูกต้อง');
          return;
        }

        // For phone login, do NOT fall back to OTP on invalid-credential.
        // This preserves “OTP only first time”; invalid-credential is treated
        // as wrong password for an existing linked account.
        if (e.code == 'invalid-credential') {
          _showSnack('รหัสผ่านไม่ถูกต้อง');
          return;
        }

        if (e.code != 'user-not-found') {
          _showSnack(e.message ?? 'เข้าสู่ระบบไม่สำเร็จ');
          return;
        }
      } catch (_) {
        // Continue below to OTP flow.
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }

      if (!mounted) return;
      final nav = Navigator.of(context);
      final ok = await nav.push<bool>(
        MaterialPageRoute(builder: (_) => PhoneAuthScreen(initialPhone: input)),
      );
      if (!mounted) return;
      if (ok == true) nav.pop(true);
      return;
    }

    if (!_isValidEmailFormat(input)) {
      _showSnack('รูปแบบอีเมลไม่ถูกต้อง');
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: input,
        password: password,
      );

      final user = FirebaseAuth.instance.currentUser;
      if (user != null && user.emailVerified == false) {
        if (!mounted) return;
        final nav = Navigator.of(context);
        final ok = await nav.push<bool>(
          MaterialPageRoute(builder: (_) => EmailVerifyScreen(email: input)),
        );
        if (ok == true) {
          _goToAppFirstPage();
          return;
        }

        // If not verified, do not proceed.
        _showSnack('กรุณายืนยันอีเมลก่อน');
        return;
      }

      if (_isPasswordSaved) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('saved_password_$input', password);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      String message = 'ไม่สามารถเข้าสู่ระบบได้';
      if (e.code == 'wrong-password') {
        message = 'รหัสผ่านไม่ถูกต้อง';
      } else if (e.code == 'user-not-found') {
        // Auto-signup when no account exists.
        if (!mounted) return;
        final nav = Navigator.of(context);
        try {
          final ok = await _autoSignupAndVerifyEmail(
            nav: nav,
            email: input,
            password: password,
          );
          if (ok) {
            _goToAppFirstPage();
            return;
          }
          message = 'กรุณายืนยันอีเมลก่อนเข้าสู่ระบบ';
        } on FirebaseAuthException catch (e2) {
          if (e2.code == 'email-already-in-use') {
            message = 'อีเมลนี้ถูกใช้งานแล้ว กรุณากด “ลืมรหัสผ่าน?” เพื่อเปลี่ยนรหัสผ่าน';
          } else {
            message = e2.message ?? 'สมัครใช้งานไม่สำเร็จ';
          }
        } catch (_) {
          message = 'สมัครใช้งานไม่สำเร็จ';
        }
      } else if (e.code == 'invalid-credential') {
        // Some platforms return invalid-credential for both wrong-password and user-not-found.
        // To satisfy the UX:
        // - If email exists => show "รหัสผ่านไม่ถูกต้อง"
        // - If email doesn't exist => treat as signup => go verify email
        if (!mounted) return;
        final nav = Navigator.of(context);
        try {
          final ok = await _autoSignupAndVerifyEmail(
            nav: nav,
            email: input,
            password: password,
          );
          if (ok) {
            _goToAppFirstPage();
            return;
          }
          message = 'กรุณายืนยันอีเมลก่อนเข้าสู่ระบบ';
        } on FirebaseAuthException catch (e2) {
          if (e2.code == 'email-already-in-use') {
            message = 'อีเมลนี้ถูกใช้งานแล้ว กรุณากด “ลืมรหัสผ่าน?” เพื่อเปลี่ยนรหัสผ่าน';
          } else {
            message = e2.message ?? 'สมัครใช้งานไม่สำเร็จ';
          }
        } catch (_) {
          message = 'สมัครใช้งานไม่สำเร็จ';
        }
      } else if (e.code == 'invalid-email') {
        message = 'รูปแบบอีเมลไม่ถูกต้อง';
      } else if (e.code == 'user-disabled') {
        message = 'บัญชีนี้ถูกปิดการใช้งาน';
      }
      _showSnack(message);
    } catch (_) {
      _showSnack('ไม่สามารถเข้าสู่ระบบได้');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isSocialLoading = true;
      _socialLoadingKey = 'google';
    });

    try {
      if (kIsWeb) {
        final provider = GoogleAuthProvider();
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        final googleSignIn = GoogleSignIn.instance;
        await googleSignIn.initialize();
        if (!googleSignIn.supportsAuthenticate()) {
          throw Exception('แพลตฟอร์มนี้ไม่รองรับ Google Sign-In');
        }

        final googleUser = await googleSignIn.authenticate();
        final googleAuth = googleUser.authentication;

        final credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(credential);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      debugPrint('Firebase google sign-in failed: ${e.code}');
      _showSnack('ไม่สามารถเข้าสู่ระบบด้วย Google ได้ (${e.code})');
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      _showSnack('ไม่สามารถเข้าสู่ระบบด้วย Google ได้');
    } finally {
      if (mounted) {
        setState(() {
          _isSocialLoading = false;
          _socialLoadingKey = null;
        });
      }
    }
  }

  Widget _socialButton({
    required VoidCallback? onPressed,
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
    required String buttonKey,
    String? assetImage,
    IconData? icon,
  }) {
    final isLoading = _isSocialLoading && _socialLoadingKey == buttonKey;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (_isLoading || _isSocialLoading) ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
          side: BorderSide(color: Colors.grey.shade300),
        ),
        icon: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
                ),
              )
            : (assetImage != null
                  ? Image.asset(
                      assetImage,
                      width: 22,
                      height: 22,
                      fit: BoxFit.contain,
                    )
                  : Icon(icon, size: 22, color: foregroundColor)),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            color: foregroundColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('เข้าสู่ระบบ'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _LoginHeader(),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              autofillHints: const [
                AutofillHints.username,
                AutofillHints.email,
              ],
              decoration: InputDecoration(
                labelText: 'อีเมลหรือเบอร์โทร',
                hintText: 'user@example.com หรือ 0812345678',
                prefixIcon: const Icon(Icons.account_circle),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[50],
              ),
              onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: !_isPasswordVisible,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'รหัสผ่าน',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _isPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _isPasswordVisible = !_isPasswordVisible),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[50],
              ),
              onFieldSubmitted: (_) {
                if (!_isLoading) _signInWithEmail();
              },
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _forgotPassword,
                  child: const Text(
                    'ลืมรหัสผ่าน?',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _isPasswordSaved,
                        onChanged: (bool? value) async {
                          final input = _emailController.text.trim();
                          if (value == true && input.isNotEmpty) {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setString(
                              'saved_password_$input',
                              _passwordController.text,
                            );
                          }
                          setState(() => _isPasswordSaved = value ?? false);
                        },
                        activeColor: AppColors.accent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'บันทึกรหัสผ่าน',
                      style: TextStyle(fontSize: 14, color: Color(0xFF718096)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _signInWithEmail,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text(
                      'เข้าสู่ระบบ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            const SizedBox(height: 24),
            const _OrDivider(),
            const SizedBox(height: 24),
            _socialButton(
              onPressed: _isSocialLoading ? null : _signInWithGoogle,
              assetImage:
                  'assets/van_merchant/file_0000000075b0720680f74d4375d75c25.png',
              label: 'เข้าสู่ระบบด้วย Google',
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              buttonKey: 'google',
            ),
            const SizedBox(height: 24),
            Center(
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: const Text(
                  '← ย้อนกลับ',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _LoginHeader extends StatelessWidget {
  const _LoginHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 40),
        Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20.0),
              child: const Image(
                image: AssetImage('assets/icons/app_icon.png'),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'ถุงทอง ลอตเตอรี่',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2C3E50),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider()),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('หรือ', style: TextStyle(color: Colors.grey)),
        ),
        Expanded(child: Divider()),
      ],
    );
  }
}
