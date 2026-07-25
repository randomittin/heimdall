// MUTANT chat-trusts-bare-chatid — INV-CHAT removed.
//
// The chat verb resolves its team by TRUSTING the bare chat_id instead of the persisted
// {chat_id<->HAID<->team} binding (chat_link.resolve). An UNBOUND / forged chat_id is now
// handed a team (team A's partition) and its read verbs return team data — exactly the
// "a chat handle trusted bare" failure §2 warns against. The forgery attack SUCCEEDS ->
// attack "C1-unbound-chat" returns ALLOW (a team resolved for an unbound handle) where the
// acceptance oracle demands DENY -> the oracle goes RED at C1-unbound-chat.
import { evaluateAttack } from "../model.mjs";

const GATES = { chatTrustsBareChatId: true };

export default function evaluate(attackId) {
  return evaluateAttack(GATES, attackId);
}
