import { describe, it, expect } from "vitest";
import {
  bumpUnread,
  clearUnread,
  getUnread,
  type LedgerStorage,
  type LedgerTransaction,
} from "../src/badge-ledger";

/**
 * Minimal in-memory `LedgerStorage` that mirrors the DO contract we rely on:
 *   - `transaction` serializes nested mutations via a chained promise (good
 *     enough for vitest — the DO single-threaded runtime gives the same
 *     guarantee in production).
 *   - `get` returns a structured-clone of the stored value so callers can
 *     safely mutate their local copy without leaking into storage.
 */
function createFakeStorage(): LedgerStorage & { inspect(): Map<string, unknown> } {
  const map = new Map<string, unknown>();
  let chain: Promise<unknown> = Promise.resolve();

  const txn: LedgerTransaction = {
    async get<T = unknown>(key: string): Promise<T | undefined> {
      const value = map.get(key);
      if (value === undefined) return undefined;
      return structuredClone(value) as T;
    },
    async put<T = unknown>(key: string, value: T): Promise<void> {
      map.set(key, structuredClone(value));
    },
    async delete(key: string): Promise<boolean> {
      return map.delete(key);
    },
  };

  return {
    async transaction<T>(closure: (t: LedgerTransaction) => Promise<T>): Promise<T> {
      const next = chain.then(() => closure(txn));
      chain = next.catch(() => undefined);
      return next;
    },
    async get<T = unknown>(key: string): Promise<T | undefined> {
      const value = map.get(key);
      if (value === undefined) return undefined;
      return structuredClone(value) as T;
    },
    inspect(): Map<string, unknown> {
      return map;
    },
  };
}

describe("badge-ledger", () => {
  it("bumpUnread increments total and byThread", async () => {
    const storage = createFakeStorage();
    const peer = "1111111111111111";

    const after1 = await bumpUnread(storage, peer, "thread-a");
    expect(after1).toBe(1);

    const after2 = await bumpUnread(storage, peer, "thread-a");
    expect(after2).toBe(2);

    const after3 = await bumpUnread(storage, peer, "thread-b");
    expect(after3).toBe(3);

    const snapshot = await getUnread(storage, peer);
    expect(snapshot.total).toBe(3);
    expect(snapshot.byThread).toEqual({ "thread-a": 2, "thread-b": 1 });
    expect(snapshot.updatedAt).toBeGreaterThan(0);
  });

  it("bumpUnread with null threadId increments total only", async () => {
    const storage = createFakeStorage();
    const peer = "2222222222222222";

    await bumpUnread(storage, peer, null);
    await bumpUnread(storage, peer, null);

    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(2);
    expect(snap.byThread).toEqual({});
  });

  it("clearUnread by threadId subtracts that thread's count from total", async () => {
    const storage = createFakeStorage();
    const peer = "3333333333333333";

    await bumpUnread(storage, peer, "thread-a"); // a: 1
    await bumpUnread(storage, peer, "thread-a"); // a: 2
    await bumpUnread(storage, peer, "thread-b"); // b: 1
    // total = 3

    const afterClear = await clearUnread(storage, peer, { threadId: "thread-a" });
    expect(afterClear).toBe(1);

    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(1);
    expect(snap.byThread).toEqual({ "thread-b": 1 });
  });

  it("clearUnread with all=true wipes the row and returns 0", async () => {
    const storage = createFakeStorage();
    const peer = "4444444444444444";

    await bumpUnread(storage, peer, "thread-a");
    await bumpUnread(storage, peer, "thread-b");

    const result = await clearUnread(storage, peer, { all: true });
    expect(result).toBe(0);

    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(0);
    expect(snap.byThread).toEqual({});
    expect(snap.updatedAt).toBe(0); // empty snapshot
    // Row should be deleted, not merely zeroed.
    expect(storage.inspect().has(`unread:${peer}`)).toBe(false);
  });

  it("clearUnread on empty row is a no-op", async () => {
    const storage = createFakeStorage();
    const peer = "5555555555555555";

    const result = await clearUnread(storage, peer, { all: true });
    expect(result).toBe(0);

    const result2 = await clearUnread(storage, peer, { threadId: "nonexistent" });
    expect(result2).toBe(0);
  });

  it("clearUnread on unknown thread is a no-op (preserves total)", async () => {
    const storage = createFakeStorage();
    const peer = "6666666666666666";

    await bumpUnread(storage, peer, "thread-a");
    const result = await clearUnread(storage, peer, { threadId: "thread-z" });
    expect(result).toBe(1);
    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(1);
  });

  it("clearUnread that drains the last thread removes the row entirely", async () => {
    const storage = createFakeStorage();
    const peer = "7777777777777777";

    await bumpUnread(storage, peer, "thread-a");
    await clearUnread(storage, peer, { threadId: "thread-a" });

    expect(storage.inspect().has(`unread:${peer}`)).toBe(false);
    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(0);
  });

  it("getUnread returns zero snapshot for missing peer", async () => {
    const storage = createFakeStorage();
    const snap = await getUnread(storage, "8888888888888888");
    expect(snap).toEqual({ total: 0, byThread: {}, updatedAt: 0 });
  });

  it("concurrent bumps on the same peer serialize via transaction", async () => {
    const storage = createFakeStorage();
    const peer = "9999999999999999";

    // Fire 10 concurrent bumps; they must all land (no lost writes).
    const promises = Array.from({ length: 10 }, (_, i) =>
      bumpUnread(storage, peer, i % 2 === 0 ? "thread-a" : "thread-b")
    );
    const totals = await Promise.all(promises);

    // Each call should see a strictly increasing total thanks to serialization.
    const sorted = [...totals].sort((a, b) => a - b);
    expect(sorted).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(10);
    expect(snap.byThread["thread-a"]).toBe(5);
    expect(snap.byThread["thread-b"]).toBe(5);
  });

  it("concurrent clears are serialized and never produce negative totals", async () => {
    const storage = createFakeStorage();
    const peer = "aaaabbbbccccdddd";

    await bumpUnread(storage, peer, "thread-a");
    await bumpUnread(storage, peer, "thread-a");
    await bumpUnread(storage, peer, "thread-b");

    // Two concurrent clears: one for thread-a, one for thread-b.
    const [a, b] = await Promise.all([
      clearUnread(storage, peer, { threadId: "thread-a" }),
      clearUnread(storage, peer, { threadId: "thread-b" }),
    ]);

    // Order is not deterministic, but totals must be in {0, 1}.
    expect(a).toBeGreaterThanOrEqual(0);
    expect(b).toBeGreaterThanOrEqual(0);
    const snap = await getUnread(storage, peer);
    expect(snap.total).toBe(0);
  });
});
