// A correct settlement webhook (profile settlement-webhook/1). The golden the `attack`
// gate must PROVE: every attack in the battery fails to break it.
//
// The event id is claimed with one atomic putIfAbsent BEFORE any money moves, so two
// deliveries of the same event — sequential, or a retry racing the first attempt —
// cannot both apply. The fee is computed in exact integer cents and rounded half-up.
// Reads are owner-only, by exact identity.

export default function createWebhook({ store }) {
  return {
    async handleEvent(event) {
      const claimed = await store.putIfAbsent(`event:${event.id}`, true);
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
