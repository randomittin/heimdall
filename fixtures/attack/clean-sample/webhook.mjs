// Settlement webhook: credits a merchant account when the payment provider reports a
// settled payment. The provider retries a delivery it did not get an answer for, so an
// event is claimed atomically before any money moves: a redelivery, even one racing the
// first attempt, can never be applied twice.

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
