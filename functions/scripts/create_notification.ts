import { initializeApp } from 'firebase-admin/app';
import { FieldValue, getFirestore, Timestamp } from 'firebase-admin/firestore';

initializeApp();

const COLLECTION = 'notifications';

type Audience = 'all' | 'user' | 'uids';

function getArg(name: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return undefined;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

function parseAudience(v: string | undefined): Audience {
  const s = (v ?? 'all').trim().toLowerCase();
  if (s === 'user') return 'user';
  if (s === 'uids') return 'uids';
  return 'all';
}

function parseBool(v: string | undefined): boolean | undefined {
  if (v == null) return undefined;
  const s = v.trim().toLowerCase();
  if (s === 'true' || s === '1' || s === 'yes' || s === 'y') return true;
  if (s === 'false' || s === '0' || s === 'no' || s === 'n') return false;
  return undefined;
}

async function main() {
  const db = getFirestore();

  const audience = parseAudience(getArg('audience'));
  const title = (getArg('title') ?? 'แจ้งเตือน').trim();
  const body = (getArg('body') ?? '').trim();
  const type = (getArg('type') ?? 'generic').trim();
  const active = parseBool(getArg('active')) ?? true;

  const uid = (getArg('uid') ?? '').trim();
  const uidsCsv = (getArg('uids') ?? '').trim();
  const uids = uidsCsv
    ? uidsCsv
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
    : [];

  const useServerTimestamp = !hasFlag('clientTime');

  const data: Record<string, unknown> = {
    active,
    audience,
    type,
    title,
    body,
    createdAt: useServerTimestamp ? FieldValue.serverTimestamp() : Timestamp.now(),
    updatedAt: useServerTimestamp ? FieldValue.serverTimestamp() : Timestamp.now(),
  };

  if (audience === 'user') {
    if (!uid) {
      throw new Error('Missing --uid when --audience user');
    }
    data.uid = uid;
  }

  if (audience === 'uids') {
    if (uids.length === 0) {
      throw new Error('Missing --uids when --audience uids (comma-separated)');
    }
    data.uids = uids;
  }

  const ref = await db.collection(COLLECTION).add(data);
  console.log(`Created ${COLLECTION}/${ref.id}`);
  console.log({ ...data, createdAt: '(serverTimestamp)', updatedAt: '(serverTimestamp)' });
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
