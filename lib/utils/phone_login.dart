String? normalizePhoneToE164Thai(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;

  // Already E.164.
  if (raw.startsWith('+')) {
    final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (RegExp(r'^\+\d{8,15}$').hasMatch(digits)) return digits;
    return null;
  }

  final digitsOnly = raw.replaceAll(RegExp(r'[^0-9]'), '');

  // Thai local: 0XXXXXXXXX.
  if (digitsOnly.startsWith('0') && digitsOnly.length >= 9) {
    final without0 = digitsOnly.substring(1);
    return '+66$without0';
  }

  // If user typed 66xxxxxxxxx without '+'.
  if (digitsOnly.startsWith('66') && digitsOnly.length >= 10) {
    return '+$digitsOnly';
  }

  return null;
}

String phoneToPseudoEmailFromE164(String e164) {
  final digits = e164.replaceAll(RegExp(r'[^0-9]'), '');
  // Use a non-real domain; this is purely an identifier for email/password auth.
  return 'phone_$digits@tungtong.local';
}

String? phoneInputToPseudoEmail(String input) {
  final e164 = normalizePhoneToE164Thai(input);
  if (e164 == null) return null;
  return phoneToPseudoEmailFromE164(e164);
}
