// MUTANT dedupes-by-account: the golden webhook, but the idempotency claim is keyed by
// the ACCOUNT instead of the event id. Redelivery of an event is still absorbed, but a
// second, different event for the same account is dropped as if it were a duplicate and
// never credited (an over-eager fix for the duplicate-settlement bug).
// (Exactly one defect: the claim key.)

export default function createWebhook({ store }) {
  return {
    async handleEvent(event) {
      const claimed = await store.putIfAbsent(`event:${event.account}`, true);
      if (!claimed) return { status: 'duplicate' };
      const fee = Math.floor((event.gross_cents * 29 + 500) / 1000);
      const net = event.gross_cents - fee;
      await store.incr(`balance:${event.account}`, net);
      await store.set(`settlement:${event.id}`, {
        event_id: event.id,
        account: event.account,
        gross_cents: event.gross_cents,
        fee_cents: fee,
        net_cents: net,
      });
      return { status: 'applied' };
    },

    async getBalance(account, caller) {
      if (caller !== account) return null;
      return (await store.get(`balance:${account}`)) || 0;
    },

    async getSettlement(eventId, caller) {
      const record = await store.get(`settlement:${eventId}`);
      return record && record.account === caller ? record : null;
    },
  };
}
