import 'pdf_cache_stub.dart'
    if (dart.library.io) 'pdf_cache_io.dart' as impl;

class PdfCache {
  static Future<void> maybeAutoDownloadLatest({
    required String? drawDateIso,
    required String? storagePath,
    required String? sha256,
  }) {
    return impl.PdfCacheImpl.maybeAutoDownloadLatest(
      drawDateIso: drawDateIso,
      storagePath: storagePath,
      sha256: sha256,
    );
  }
}
