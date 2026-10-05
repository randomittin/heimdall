// MUTANT prefix-ownership: the golden webhook, but ownership is decided by `startsWith`
// instead of identity. A caller whose id merely begins with the account id (acct_A1
// reading acct_A) is treated as the owner, while an unrelated account and the anonymous
// caller are still refused — so a test that only tries "some other account" never sees it.
// (Exactly one defect: prefix match in the ownership check.)

const owns = (caller, account) => typeof caller === 'string' && caller.startsWith(account);

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
      if (!owns(caller, account)) return null;
      return (await store.get(`balance:${account}`)) || 0;
    },

    async getSettlement(eventId, caller) {
      const record = await store.get(`settlement:${eventId}`);
      return record && owns(caller, record.account) ? record : null;
    },
  };
}
