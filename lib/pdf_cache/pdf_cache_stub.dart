class PdfCacheImpl {
  static Future<void> maybeAutoDownloadLatest({
    required String? drawDateIso,
    required String? storagePath,
    required String? sha256,
  }) async {
    // No-op on platforms without dart:io (e.g., web).
  }
}
