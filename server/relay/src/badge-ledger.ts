/**
 * Per-peer unread badge ledger, persisted in DO storage.
 *
 * Storage key layout: `unread:{peerIdHex}` → {@link UnreadSnapshot}
 *
 *   total      — aggregate unread count across all threads for this peer
 *   byThread   — map of threadId → unread count within that thread (for
 *                fine-grained clear). Thread IDs are opaque to relay: for DM /
 *                group traffic we use the sender PeerID hex as a stable
 *                per-contact thread key (relay is zero-knowledge and cannot
 *                decrypt the channel UUID).
 *   updatedAt  — wall-clock millis of the last mutation
 *
 * All mutations go through `state.storage.transaction` so concurrent bumps /
 * clears on the same peer serialize correctly — the DO single-threaded model
 * gives us that for free, but wrapping the read-modify-write keeps the
 * guarantee explicit and survives future refactors.
 *
 * This module is purely a storage helper; it has no knowledge of pushes,
 * cooldowns, or WebSocket lifecycle.
 */

export interface UnreadSnapshot {
  total: number;
  byThread: Record<string, number>;
  updatedAt: number;
}

/** Storage shape for one peer. */
interface StoredUnread {
  total: number;
  byThread: Record<string, number>;
  updatedAt: number;
}

/**
 * Minimal transactional storage contract we rely on. Matches the subset of
 * `DurableObjectStorage` that the unit tests mock. Broader than strictly
 * necessary so callers can pass `state.storage` directly.
 */
export interface LedgerStorage {
  transaction<T>(
    closure: (txn: LedgerTransaction) => Promise<T>
  ): Promise<T>;
  get<T = unknown>(key: string): Promise<T | undefined>;
}

export interface LedgerTransaction {
  get<T = unknown>(key: string): Promise<T | undefined>;
  put<T = unknown>(key: string, value: T): Promise<void>;
  delete(key: string): Promise<boolean>;
}

const UNREAD_PREFIX = "unread:";

function unreadKey(peerIdHex: string): string {
  return `${UNREAD_PREFIX}${peerIdHex}`;
}

function emptySnapshot(): UnreadSnapshot {
  return { total: 0, byThread: {}, updatedAt: 0 };
}

/**
 * Atomically increment the unread counter for `peerIdHex`. When `threadId` is
 * provided the per-thread entry is also bumped. Returns the new total.
 */
export async function bumpUnread(
  storage: LedgerStorage,
  peerIdHex: string,
  threadId: string | null
): Promise<number> {
  return await storage.transaction(async (txn) => {
    const key = unreadKey(peerIdHex);
    const existing = (await txn.get<StoredUnread>(key)) ?? emptySnapshot();
    const next: StoredUnread = {
      total: existing.total + 1,
      byThread: { ...existing.byThread },
      updatedAt: Date.now(),
    };
    if (threadId) {
      next.byThread[threadId] = (next.byThread[threadId] ?? 0) + 1;
    }
    await txn.put(key, next);
    return next.total;
  });
}

/**
 * Atomically clear unread state. Exactly one of `threadId` or `all` must be
 * supplied (enforced by the caller — we tolerate both for robustness).
 *
 *  - `all: true`      → wipe the row entirely, return 0.
 *  - `threadId: "x"`  → subtract byThread[x] from total, delete that entry,
 *                       persist the remainder. Returns the new total.
 *
 * Returns the new total after the clear.
 */
export async function clearUnread(
  storage: LedgerStorage,
  peerIdHex: string,
  opts: { threadId?: string; all?: boolean }
): Promise<number> {
  return await storage.transaction(async (txn) => {
    const key = unreadKey(peerIdHex);
    const existing = await txn.get<StoredUnread>(key);
    if (!existing) {
      return 0;
    }
    if (opts.all) {
      await txn.delete(key);
      return 0;
    }
    if (opts.threadId) {
      const delta = existing.byThread[opts.threadId] ?? 0;
      if (delta === 0) {
        // Nothing to clear for this thread — leave the row untouched.
        return existing.total;
      }
      const remaining = { ...existing.byThread };
      delete remaining[opts.threadId];
      const next: StoredUnread = {
        total: Math.max(0, existing.total - delta),
        byThread: remaining,
        updatedAt: Date.now(),
      };
      if (next.total === 0 && Object.keys(next.byThread).length === 0) {
        await txn.delete(key);
        return 0;
      }
      await txn.put(key, next);
      return next.total;
    }
    // Neither `all` nor `threadId` supplied — treat as no-op.
    return existing.total;
  });
}

/**
 * Snapshot the unread state for `peerIdHex`. Returns a zero-value snapshot if
 * the row does not exist. Does not mutate storage.
 */
export async function getUnread(
  storage: LedgerStorage,
  peerIdHex: string
): Promise<UnreadSnapshot> {
  const stored = await storage.get<StoredUnread>(unreadKey(peerIdHex));
  if (!stored) return emptySnapshot();
  return {
    total: stored.total,
    byThread: { ...stored.byThread },
    updatedAt: stored.updatedAt,
  };
}
