// MUTANT racy-duplicate: the golden webhook with its atomic claim replaced by a
// check-then-act. A retry that arrives while the first attempt is still in flight (the
// event is only marked processed AFTER the account is credited) passes the check and
// credits the account a second time. A retry that arrives after the first attempt has
// finished is rejected correctly — so a test that delivers the event twice in a row never
// sees the bug. This is the "webhook + retry within 50ms" defect.
// (Exactly one defect: `get` then `set` instead of `putIfAbsent`.)

export default function createWebhook({ store }) {
  return {
    async handleEvent(event) {
      if (await store.get(`event:${event.id}`)) return { status: 'duplicate' };
      const fee = Math.floor((event.gross_cents * 29 + 500) / 1000);
      const net = event.gross_cents - fee;
      await store.incr(`balance:${event.account}`, net);
      await store.set(`event:${event.id}`, true);
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
