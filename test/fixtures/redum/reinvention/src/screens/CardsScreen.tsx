// CardsScreen.tsx — the REINVENTION change. Instead of importing the existing
// card store, this screen RE-DECLARES the slice, the selector, and the MMKV key:
//
//   • a second `createSlice({ name: "cards" })`  → duplicates the `cards` slice
//   • its own `selectCards`                       → duplicates the existing selector
//   • the SAME MMKV key string "cards.cache.v1"   → under a new const CARD_CACHE,
//                                                    duplicating the storage slot
//
// This is the low-reuse outcome Redum exists to catch. The commit-time gate must
// FLAG these residual duplicates against the base store.
import { createSlice } from "@reduxjs/toolkit";
import { MMKV } from "react-native-mmkv";

const storage = new MMKV();

// DUPLICATE storage slot: same string as the existing CARDS_CACHE_KEY, new const.
const CARD_CACHE = "cards.cache.v1";

// DUPLICATE slice: re-creates the "cards" store domain.
const cardsSlice = createSlice({
  name: "cards",
  initialState: { items: [] },
  reducers: {
    setCards(state, action) {
      state.items = action.payload;
    },
  },
});

// DUPLICATE selector: re-derives what the existing selectCards already returns.
export const selectCards = (state) => state.cards.items;

export function CardsScreen() {
  const raw = storage.getString(CARD_CACHE);
  const cards = raw ? JSON.parse(raw) : [];
  return cards;
}
