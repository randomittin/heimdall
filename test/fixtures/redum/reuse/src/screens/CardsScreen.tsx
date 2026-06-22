// CardsScreen.tsx — the GENUINE-REUSE change (the control case). The SAME screen,
// written the right way: it IMPORTS and CALLS the existing store units instead of
// re-declaring them —
//
//   • selectCards     ← imported from the existing cardsSlice (reused, not re-declared)
//   • readCardsCache  ← imported from the existing cardsStorage (reuses the MMKV key)
//
// No duplicate slice, no duplicate selector, no duplicate MMKV key. This is what
// Redum's plan-time factoring steers the agent toward — and the commit-time gate
// must NOT flag it (proving the gate fires on duplicates, not on real reuse).
import { useSelector } from "react-redux";
import { selectCards } from "../store/cardsSlice";
import { readCardsCache } from "../store/cardsStorage";

export function CardsScreen() {
  const cards = useSelector(selectCards);
  const cached = readCardsCache();
  return cards.length ? cards : cached;
}
