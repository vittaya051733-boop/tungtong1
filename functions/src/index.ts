import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { logger } from 'firebase-functions';
import { onObjectFinalized } from 'firebase-functions/v2/storage';

export {
  syncLatestLotteryPdf,
  syncLatestLotteryPdfHttp,
  backfillLastYearFromApi,
  backfillLastYearFromApiHttp,
  backfillLastYearPdfFromLotteryCo,
  backfillLastYearPdfFromLotteryCoHttp,
  completeLastYearToFullResultsHttp,
  completeFromExistingPdfsHttp,
  ingestLotteryPdfUploadHttp,
  debugGetLotteryDrawHttp,
} from './lottery_pdf_sync';

initializeApp();

const INDEX_COLLECTION = 'ticket_image_index';

// Keep this aligned with the Flutter app's known ticket prefixes.
const ALLOWED_PREFIXES = [
  'lottery_copy/ookaYaimgZVdw5zXAVpsY',
  'lottery_copy',
  'lottery',
];

function isImagePath(path: string): boolean {
  const p = path.toLowerCase();
  if (!p.includes('.')) return true;
  return (
    p.endsWith('.png') ||
    p.endsWith('.jpg') ||
    p.endsWith('.jpeg') ||
    p.endsWith('.webp')
  );
}

function matchesAllowedPrefix(path: string): boolean {
  return ALLOWED_PREFIXES.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));
}

function docIdFromPath(path: string): string {
  return path.split('/').join('_');
}

function parseDigitsFromCopyImagePath(path: string): string | null {
  // Expected: lottery_copy/<uid>/<digits>_...jpg
  const m = /^lottery_copy\/[^/]+\/(\d+)_/i.exec(path);
  if (!m) return null;
  const digits = (m[1] ?? '').trim();
  if (!digits) return null;
  // Match client-side behavior: ignore placeholder values.
  if (digits === '000000') return null;
  return digits;
}

function copyImageStoragePathFromPath(path: string): string | null {
  return path.startsWith('lottery_copy/') ? path : null;
}

export const indexTicketImage = onObjectFinalized(
  {
    region: 'asia-southeast1',
    // Optional: reduce noisy triggers from non-ticket buckets.
    // Setting this may require extra IAM for the Eventarc service account.
    bucket: 'van-merchant.firebasestorage.app',
  },
  async (event) => {
    const object = event.data;
    const path = (object.name ?? '').trim();

    if (!path) return;
    if (!matchesAllowedPrefix(path)) return;
    if (!isImagePath(path)) return;

    const bucket = object.bucket ?? '';
    // Defensive guard (even though the trigger is bucket-scoped).
    if (bucket !== 'van-merchant.firebasestorage.app') return;
    const contentType = object.contentType ?? '';

    // timeCreated/updated are RFC3339 strings in metadata.
    const createdAt = object.timeCreated
      ? Timestamp.fromDate(new Date(object.timeCreated))
      : Timestamp.now();
    const updatedAt = object.updated
      ? Timestamp.fromDate(new Date(object.updated))
      : createdAt;

    const docId = docIdFromPath(path);
    const db = getFirestore();

    const copyImageStoragePath = copyImageStoragePathFromPath(path);
    const digits = copyImageStoragePath ? parseDigitsFromCopyImagePath(path) : null;

    await db.collection(INDEX_COLLECTION).doc(docId).set(
      {
        path,
        copyImageStoragePath,
        digits,
        bucket,
        contentType,
        createdAt,
        updatedAt,
        size: object.size ? Number(object.size) : null,
        generation: object.generation ?? null,
        metageneration: object.metageneration ?? null,
      },
      { merge: true }
    );

    logger.info('Indexed ticket image', { path, bucket, docId });
  }
);
