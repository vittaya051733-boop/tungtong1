import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { Storage } from '@google-cloud/storage';

initializeApp();

const INDEX_COLLECTION = 'ticket_image_index';

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

function docIdFromPath(path: string): string {
  return path.split('/').join('_');
}

function parseDigitsFromCopyImagePath(path: string): string | null {
  // Expected: lottery_copy/<uid>/<digits>_...jpg
  const m = /^lottery_copy\/[^/]+\/(\d+)_/i.exec(path);
  if (!m) return null;
  const digits = (m[1] ?? '').trim();
  if (!digits) return null;
  if (digits === '000000') return null;
  return digits;
}

function copyImageStoragePathFromPath(path: string): string | null {
  return path.startsWith('lottery_copy/') ? path : null;
}

function getArg(name: string, fallback?: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return fallback;
}

async function main() {
  const bucketName = getArg('bucket') ?? '';
  if (!bucketName) {
    throw new Error('Missing --bucket. Example: npm run backfill -- --bucket van-merchant.firebasestorage.app --prefix lottery_copy');
  }

  const prefix = getArg('prefix', 'lottery_copy') ?? 'lottery_copy';
  const pageSize = Number(getArg('pageSize', '500'));

  const storage = new Storage();
  const bucket = storage.bucket(bucketName);
  const db = getFirestore();

  console.log(`Backfill starting: bucket=${bucketName} prefix=${prefix} pageSize=${pageSize}`);

  let pageToken: string | undefined;
  let total = 0;

  while (true) {
    const [files, , apiResponse] = await bucket.getFiles({
      prefix,
      autoPaginate: false,
      maxResults: pageSize,
      pageToken,
    });

    const token = (apiResponse as any)?.nextPageToken as string | undefined;

    let batch = db.batch();
    let batchOps = 0;

    for (const f of files) {
      const name = (f.name ?? '').trim();
      if (!name) continue;
      if (!isImagePath(name)) continue;

      const copyImageStoragePath = copyImageStoragePathFromPath(name);
      const digits = copyImageStoragePath ? parseDigitsFromCopyImagePath(name) : null;

      const [meta] = await f.getMetadata();
      const createdAt = meta.timeCreated
        ? Timestamp.fromDate(new Date(meta.timeCreated))
        : Timestamp.now();
      const updatedAt = meta.updated
        ? Timestamp.fromDate(new Date(meta.updated))
        : createdAt;

      const ref = db.collection(INDEX_COLLECTION).doc(docIdFromPath(name));
      batch.set(
        ref,
        {
          path: name,
          copyImageStoragePath,
          digits,
          bucket: bucketName,
          contentType: meta.contentType ?? null,
          createdAt,
          updatedAt,
          size: meta.size ? Number(meta.size) : null,
          generation: meta.generation ?? null,
          metageneration: meta.metageneration ?? null,
        },
        { merge: true }
      );

      batchOps += 1;
      total += 1;

      if (batchOps >= 450) {
        await batch.commit();
        console.log(`Committed ${batchOps} docs (total ${total})`);
        batch = db.batch();
        batchOps = 0;
      }
    }

    if (batchOps > 0) {
      await batch.commit();
      console.log(`Committed ${batchOps} docs (total ${total})`);
    }

    if (!token) break;
    pageToken = token;
  }

  console.log(`Backfill done. total=${total}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
