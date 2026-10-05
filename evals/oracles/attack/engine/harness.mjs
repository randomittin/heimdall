// engine/harness.mjs — the deterministic virtual-time harness the attack suite drives a
// target through.
//
// WHY VIRTUAL TIME. The defect class that survives code review and unit tests is the
// race between two deliveries of one webhook (provider timeout -> retry while the first
// attempt is still in flight). Real timers make that class flaky to test: it depends on
// host speed and load. Here the store is the ONLY source of latency and it runs on a
// virtual clock, so "retry 10ms after the first delivery" is an exact, replayable
// instant, the whole battery takes milliseconds, and a verdict never depends on the
// machine it ran on.
//
// THE MODEL. Every store call completes `latencyMs` of virtual time after it is issued
// and takes effect atomically AT completion (a database round trip). A handler that does
// `await get(); await set()` therefore has a real window between the two in which a
// second delivery can slip through — exactly like a real datastore.
//
// SCOPE OF THE CONTRACT. A handler must reach the outside world only through the
// injected store. Real timers or real I/O inside a handler are not modelled; a handler
// that waits on one is reported as hung, not guessed at.

export const STORE_LATENCY_MS = 25;

const clone = (value) => (value === undefined ? undefined : structuredClone(value));

export class VirtualClock {
  constructor() {
    this.now = 0;
    this.seq = 0;
    this.timers = [];
  }

  sleep(ms) {
    return new Promise((resolve) => {
      this.timers.push({ at: this.now + ms, seq: this.seq++, resolve });
    });
  }

  hasTimers() {
    return this.timers.length > 0;
  }

  // Fire the earliest timer (ties broken by creation order) and move time to it.
  advance() {
    let best = 0;
    for (let i = 1; i < this.timers.length; i++) {
      const a = this.timers[i];
      const b = this.timers[best];
      if (a.at < b.at || (a.at === b.at && a.seq < b.seq)) best = i;
    }
    const [timer] = this.timers.splice(best, 1);
    this.now = timer.at;
    timer.resolve();
  }
}

// An in-memory async key-value store whose every operation costs `latencyMs` of virtual
// time and applies atomically at completion. Values cross the boundary by structured
// clone, like a real database, so a handler can never share mutable state with the store.
export function createStore(clock, latencyMs = STORE_LATENCY_MS) {
  const data = new Map();
  const op = (apply) => clock.sleep(latencyMs).then(apply);
  return {
    get: (key) => op(() => clone(data.get(key))),
    set: (key, value) => op(() => {
      data.set(key, clone(value));
    }),
    // atomic: resolves true iff the key was absent and is now set
    putIfAbsent: (key, value) => op(() => {
      if (data.has(key)) return false;
      data.set(key, clone(value));
      return true;
    }),
    // atomic add; a missing key counts as 0
    incr: (key, delta) => op(() => {
      const next = (data.get(key) || 0) + delta;
      data.set(key, next);
      return next;
    }),
  };
}

const nextMacrotask = () => new Promise((resolve) => setImmediate(resolve));
const realDelay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Run `scenario` (an async function) to completion on `clock`: after every macrotask all
// microtasks (the handler's continuations) have run, so the earliest pending store
// operation is the next thing that can happen — fire it, repeat. Resolves to
// { ok: true, value } | { ok: false, error }; never throws, never hangs.
export async function drive(clock, scenario, { idleLimit = 200, maxSteps = 200000 } = {}) {
  let outcome = null;
  Promise.resolve().then(scenario).then(
    (value) => {
      outcome = { ok: true, value };
    },
    (error) => {
      outcome = { ok: false, error };
    },
  );
  let idle = 0;
  for (let steps = 0; steps < maxSteps; steps++) {
    await nextMacrotask();
    if (clock.hasTimers()) {
      idle = 0;
      clock.advance();
      continue;
    }
    if (outcome) return outcome;
    if (++idle > idleLimit) {
      return { ok: false, error: new Error('the handler never settled: it is waiting on something other than the injected store') };
    }
    await realDelay(2);
  }
  return { ok: false, error: new Error('the handler kept scheduling store operations without settling') };
}

// Call into the target; a throw or rejection is an observation, not a crash of the engine.
export async function call(fn) {
  try {
    return { ok: true, value: await fn() };
  } catch (error) {
    return { ok: false, error: String((error && error.message) || error) };
  }
}
