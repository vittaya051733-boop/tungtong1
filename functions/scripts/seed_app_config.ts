import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';

initializeApp();

const CONFIG_COLLECTION = 'app_config';
const DEFAULT_CONFIG_DOC = 'global';

function getArg(name: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return undefined;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

function parseBool(value: string | undefined): boolean | undefined {
  if (value == null) return undefined;
  const v = value.trim().toLowerCase();
  if (v === 'true' || v === '1' || v === 'yes' || v === 'y') return true;
  if (v === 'false' || v === '0' || v === 'no' || v === 'n') return false;
  return undefined;
}

async function main() {
  const db = getFirestore();

  const force = hasFlag('force');

  // Keep this aligned with the Flutter client, which reads: /app_config/global
  // Allow overriding for legacy deployments.
  const configDoc = (getArg('doc') ?? DEFAULT_CONFIG_DOC).trim() || DEFAULT_CONFIG_DOC;

  const storeOpenArg = parseBool(getArg('storeOpen'));
  const closedMessageArg = getArg('closedMessage');

  const ref = db.collection(CONFIG_COLLECTION).doc(configDoc);
  const snap = await ref.get();

  const now = Timestamp.now();

  const defaults = {
    storeOpen: true,
    // Seed as empty so admins can fill their own message.
    // Client falls back to a default message when this is empty.
    closedMessage: '',
  };

  const nextData: Record<string, unknown> = {
    ...defaults,
    ...(storeOpenArg === undefined ? {} : { storeOpen: storeOpenArg }),
    ...(closedMessageArg == null ? {} : { closedMessage: closedMessageArg }),
    updatedAt: now,
  };

  if (!snap.exists) {
    await ref.set({ ...nextData, createdAt: now }, { merge: true });
    console.log(`Created ${CONFIG_COLLECTION}/${configDoc}`);
    console.log(nextData);
    return;
  }

  if (force) {
    await ref.set(nextData, { merge: true });
    console.log(`Updated (force) ${CONFIG_COLLECTION}/${configDoc}`);
    console.log(nextData);
    return;
  }

  // Non-force: only ensure required fields exist (merge defaults).
  const existing = snap.data() ?? {};
  const shouldSet: Record<string, unknown> = {
    updatedAt: now,
  };

  // Only seed storeOpen when neither `isOpen` nor `storeOpen` exists.
  // Many deployments use `isOpen` as the primary flag (Flutter reads `isOpen` first).
  const hasIsOpen = typeof (existing as any).isOpen === 'boolean';
  const hasStoreOpen = typeof (existing as any).storeOpen === 'boolean';
  if (!hasIsOpen && !hasStoreOpen) {
    shouldSet.storeOpen = nextData.storeOpen;
  }

  if (typeof existing.closedMessage !== 'string' || (existing.closedMessage as string).trim() === '') {
    shouldSet.closedMessage = nextData.closedMessage;
  }

  // Respect explicit CLI overrides even without --force.
  if (storeOpenArg !== undefined) {
    shouldSet.storeOpen = storeOpenArg;
  }
  if (closedMessageArg != null) {
    shouldSet.closedMessage = closedMessageArg;
  }

  await ref.set(shouldSet, { merge: true });
  console.log(`Ensured ${CONFIG_COLLECTION}/${configDoc} (merge)`);
  console.log(shouldSet);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
