import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PdfCacheImpl {
  static Future<void> maybeAutoDownloadLatest({
    required String? drawDateIso,
    required String? storagePath,
    required String? sha256,
  }) async {
    if (drawDateIso == null || drawDateIso.trim().isEmpty) return;
    if (storagePath == null || storagePath.trim().isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = sha256 != null && sha256.trim().isNotEmpty
          ? 'pdf_cached_${drawDateIso}_${sha256.trim()}'
          : 'pdf_cached_$drawDateIso';
      if (prefs.getBool(cacheKey) == true) return;

      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}${Platform.pathSeparator}lottery_pdfs');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      final target = File(
        '${cacheDir.path}${Platform.pathSeparator}lottery_$drawDateIso.pdf',
      );
      if (await target.exists()) {
        await prefs.setBool(cacheKey, true);
        return;
      }

      final ref = FirebaseStorage.instance.ref(storagePath);
      await ref.writeToFile(target);

      await prefs.setBool(cacheKey, true);
    } catch (_) {
      // Best-effort only.
    }
  }
}
