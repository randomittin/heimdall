// MUTANT missed-idor: the golden webhook with the ownership check removed from both
// reads. Anyone who can guess an account id or an event id — another account, or an
// anonymous caller — reads someone else's balance and settlement records (an insecure
// direct object reference). (Exactly one defect: the reads ignore `caller`.)

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

    async getBalance(account) {
      return (await store.get(`balance:${account}`)) || 0;
    },

    async getSettlement(eventId) {
      return (await store.get(`settlement:${eventId}`)) || null;
    },
  };
}
