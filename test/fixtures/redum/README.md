# Redum card-data worked example (the canonical F3 fixture)

This is the **card-data** scenario the F3 spec names as the canonical worked
example: an existing React-Native card store, and a task that would **duplicate**
its slice / selector / MMKV key instead of reusing them.

## The pre-existing repo surface (`base/`)

`base/src/store/cardsSlice.ts` — the existing card-data store:
- a Redux-Toolkit **slice** named `cards` (`createSlice({ name: "cards" })`),
- a **selector** `selectCards` (derives the card list from state),
- a second selector `selectCardById`,
- an **MMKV key** `cards.cache.v1` (the storage slot for the card cache), held in
  the `CARDS_CACHE_KEY` const.

`base/src/store/cardsStorage.ts` — the existing MMKV read/write for that key.

These are the reuse units a card-data task **should reuse**.

## The reinvention change (`reinvention/`)

`reinvention/src/screens/CardsScreen.tsx` — a new screen that, instead of
importing the existing store, **re-declares**:
- its own `selectCards` selector (duplicates the existing one),
- its own MMKV key string `cards.cache.v1` under a differently-named const
  `CARD_CACHE` (duplicates the existing storage slot — same string, two consts),
- its own `cardsSlice` re-`createSlice({ name: "cards" })` (duplicates the slice).

This is the low-reuse outcome Redum exists to prevent / catch.

## The genuine-reuse change (`reuse/`)

`reuse/src/screens/CardsScreen.tsx` — the SAME screen written the right way:
it **imports and calls** the existing `selectCards` + `CARDS_CACHE_KEY` from the
store. No duplicate slice/selector/key. This is the control case the commit-time
gate must **not** flag (proving the gate fires on duplicates, not on real reuse).

## How the tests use it

- `test/redum-fixtures.test.sh` — plan-time factoring: Redum surfaces
  `selectCards` / `cards.cache.v1` / `cardsSlice` as reuse candidates for a
  card-data task (so the agent reuses them by design).
- `test/redum-integration.test.sh` — the END-TO-END gate: a real temp repo where
  the reinvention change is applied, the REAL `heimdall-attest emit` flow runs,
  Redum's commit-time gate reads the reuse field and FLAGS the residual duplicate;
  the genuine-reuse change does NOT fire the flag.
