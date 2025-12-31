import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';

initializeApp();

const COLLECTION = 'lottery_draws';
const SKIP_DATE_ISO = '2025-12-16';

function getArg(name: string, fallback?: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return fallback;
}

function ensureIsoDate(value: unknown): string {
  if (typeof value !== 'string') throw new Error('Missing date');
  const trimmed = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) {
    throw new Error(`Unexpected date format: ${trimmed}`);
  }
  return trimmed;
}

function isoDateFromDate(d: Date): string {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function toDmyFromIso(dateIso: string): { date: string; month: string; year: string } {
  const iso = ensureIsoDate(dateIso);
  const [y, m, d] = iso.split('-');
  return { date: d, month: m, year: y };
}

type PrizeBlock = {
  price?: string;
};

type LatestLotteryData = {
  first?: PrizeBlock;
  near1?: PrizeBlock;
  second?: PrizeBlock;
  third?: PrizeBlock;
  fourth?: PrizeBlock;
  fifth?: PrizeBlock;
  last2?: PrizeBlock;
  last3f?: PrizeBlock;
  last3b?: PrizeBlock;
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function asLatestLotteryData(value: unknown): LatestLotteryData | null {
  if (!isObject(value)) return null;
  return value as LatestLotteryData;
}

function toBahtInt(price: string | undefined): number | null {
  if (!price) return null;
  const normalized = String(price).replace(/,/g, '').trim();
  if (!normalized) return null;
  const n = Number.parseFloat(normalized);
  if (!Number.isFinite(n)) return null;
  return Math.round(n);
}

function isLikelyFullAmounts(amounts: unknown): boolean {
  if (!amounts || typeof amounts !== 'object') return false;
  const obj = amounts as Record<string, unknown>;
  const keys = ['first', 'near1', 'second', 'third', 'fourth', 'fifth', 'last3', 'last3f', 'last2'] as const;
  return keys.every((k) => typeof obj[k] === 'number' && Number.isFinite(obj[k] as number));
}

async function fetchAmountsForDateIso(dateIso: string): Promise<Record<string, number | null> | null> {
  const dmy = toDmyFromIso(dateIso);
  const resp = await fetch('https://www.glo.or.th/api/lottery/getLotteryResult', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(dmy),
  });

  if (!resp.ok) {
    throw new Error(`getLotteryResult HTTP ${resp.status}`);
  }

  const payload = (await resp.json()) as any;
  const data = asLatestLotteryData(payload?.response?.data);
  if (!data) return null;

  return {
    first: toBahtInt(data.first?.price),
    near1: toBahtInt(data.near1?.price),
    second: toBahtInt(data.second?.price),
    third: toBahtInt(data.third?.price),
    fourth: toBahtInt(data.fourth?.price),
    fifth: toBahtInt(data.fifth?.price),
    last3: toBahtInt(data.last3b?.price),
    last3f: toBahtInt(data.last3f?.price),
    last2: toBahtInt(data.last2?.price),
  };
}

async function main() {
  const days = Number(getArg('days', '370'));
  const pageSize = Math.max(10, Math.min(500, Number(getArg('pageSize', '200'))));
  const limit = Number(getArg('limit', '0'));
  const dryRun = String(getArg('dryRun', 'false')).trim().toLowerCase();
  const isDryRun = dryRun === '1' || dryRun === 'true' || dryRun === 'yes';

  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - Math.max(1, Math.min(5000, Number.isFinite(days) ? days : 370)));
  const cutoffIso = isoDateFromDate(cutoff);

  const db = getFirestore();

  console.log(`Backfill amounts starting: cutoffIso=${cutoffIso} pageSize=${pageSize} dryRun=${isDryRun} limit=${limit || 'none'}`);

  let processed = 0;
  let updated = 0;
  let skipped = 0;
  let failed = 0;

  let lastDate: string | null = null;

  while (true) {
    let q = db.collection(COLLECTION).where('date', '>=', cutoffIso).orderBy('date', 'desc').limit(pageSize);
    if (lastDate) q = q.startAfter(lastDate);

    const snaps = await q.get();
    if (snaps.empty) break;

    for (const doc of snaps.docs) {
      const dateIso = ensureIsoDate(doc.get('date') ?? doc.id);
      lastDate = dateIso;

      if (dateIso === SKIP_DATE_ISO) {
        skipped++;
        continue;
      }

      const existingAmounts = doc.get('amounts');
      if (isLikelyFullAmounts(existingAmounts)) {
        skipped++;
        continue;
      }

      processed++;
      try {
        const amounts = await fetchAmountsForDateIso(dateIso);
        if (!amounts || !isLikelyFullAmounts(amounts)) {
          failed++;
          console.warn('Amounts missing/invalid from API', { dateIso, amounts });
          continue;
        }

        if (!isDryRun) {
          await db.collection(COLLECTION).doc(dateIso).set(
            {
              amounts,
              updatedAt: Timestamp.now(),
              // keep source/results/pdf untouched
            },
            { merge: true }
          );
        }

        updated++;
        if (updated % 10 === 0) {
          console.log(`Progress: updated=${updated} processed=${processed} skipped=${skipped} failed=${failed} last=${dateIso}`);
        }

        if (limit && updated >= limit) {
          console.log('Reached limit, stopping.', { limit, updated, processed, skipped, failed, last: dateIso });
          return;
        }
      } catch (e) {
        failed++;
        console.warn('Failed to backfill amounts', { dateIso, error: String((e as Error)?.message ?? e) });
      }
    }

    if (snaps.size < pageSize) break;
  }

  console.log('Backfill amounts done.', { processed, updated, skipped, failed, cutoffIso, dryRun: isDryRun });
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
