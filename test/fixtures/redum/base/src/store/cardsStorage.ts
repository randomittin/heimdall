// cardsStorage.ts — the PRE-EXISTING MMKV read/write for the card cache. Uses the
// canonical CARDS_CACHE_KEY from cardsSlice — the single source of truth for the
// storage slot. A card-data task should reuse readCardsCache / writeCardsCache
// rather than open the same key under a new const.
import { MMKV } from "react-native-mmkv";
import { Card, CARDS_CACHE_KEY } from "./cardsSlice";

const storage = new MMKV();

export function writeCardsCache(cards: Card[]) {
  storage.set(CARDS_CACHE_KEY, JSON.stringify(cards));
}

export function readCardsCache(): Card[] {
  const raw = storage.getString(CARDS_CACHE_KEY);
  return raw ? (JSON.parse(raw) as Card[]) : [];
}
