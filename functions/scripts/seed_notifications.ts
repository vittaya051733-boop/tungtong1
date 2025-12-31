import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';

initializeApp();

const COLLECTION = 'notifications';

function getArg(name: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return undefined;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

async function main() {
  const db = getFirestore();
  const now = Timestamp.now();

  // Creates a non-active seed doc so the collection appears in Firestore console.
  // Client should ignore docs with active=false.
  const force = hasFlag('force');

  const seedId = getArg('id') ?? '_seed';
  const ref = db.collection(COLLECTION).doc(seedId);

  const snap = await ref.get();
  if (snap.exists && !force) {
    console.log(`Seed doc already exists: ${COLLECTION}/${seedId}`);
    return;
  }

  await ref.set(
    {
      active: false,
      audience: 'all',
      type: 'seed',
      title: 'seed',
      body: 'seed',
      createdAt: now,
      updatedAt: now,
    },
    { merge: true }
  );

  console.log(`Ensured ${COLLECTION}/${seedId}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
