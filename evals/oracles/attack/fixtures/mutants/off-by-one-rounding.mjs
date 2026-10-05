// MUTANT off-by-one-rounding: the golden webhook with the fee truncated instead of
// rounded half-up. At half-cent amounts and wherever the exact fee has a fractional part
// of .5 or more, the fee is one cent too small and the account is credited one cent too
// much; amounts that happen to land on a whole cent (or below .5) look right, which is how
// this survives casual checking. (Exactly one defect: Math.floor of the exact fee.)

export default function createWebhook({ store }) {
  return {
    async handleEvent(event) {
      const claimed = await store.putIfAbsent(`event:${event.id}`, true);
      if (!claimed) return { status: 'duplicate' };
      const fee = Math.floor((event.gross_cents * 29) / 1000);
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
