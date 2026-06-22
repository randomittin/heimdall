// cardsSlice.ts — the PRE-EXISTING card-data store. The reuse units a card-data
// task should REUSE (not re-declare): the `cards` slice, the `selectCards` /
// `selectCardById` selectors, and the `cards.cache.v1` MMKV key.
import { createSlice, PayloadAction } from "@reduxjs/toolkit";

export interface Card {
  id: string;
  title: string;
  last4: string;
}

interface CardsState {
  items: Card[];
  loading: boolean;
}

const initialState: CardsState = { items: [], loading: false };

// the canonical MMKV storage slot for the card cache. ONE source of truth.
export const CARDS_CACHE_KEY = "cards.cache.v1";

export const cardsSlice = createSlice({
  name: "cards",
  initialState,
  reducers: {
    setCards(state, action: PayloadAction<Card[]>) {
      state.items = action.payload;
    },
    setLoading(state, action: PayloadAction<boolean>) {
      state.loading = action.payload;
    },
  },
});

export const { setCards, setLoading } = cardsSlice.actions;

// the existing selectors — derive card reads from the store.
export const selectCards = (state: { cards: CardsState }) => state.cards.items;

export const selectCardById = (state: { cards: CardsState }, id: string) =>
  state.cards.items.find((c) => c.id === id);

export default cardsSlice.reducer;
