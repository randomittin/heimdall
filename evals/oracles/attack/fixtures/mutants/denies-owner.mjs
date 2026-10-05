// MUTANT denies-owner: the golden webhook "hardened" into uselessness — the reads refuse
// everybody, the owner included. Nothing leaks, so every refusal attack survives; but the
// account owner can no longer see their own balance or settlement, which the control
// attacks and every delivery read-back catch. This is the guard against fixing an IDOR by
// breaking the feature. (Exactly one defect: the ownership check refuses unconditionally.)

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

    async getBalance() {
      return null;
    },

    async getSettlement() {
      return null;
    },
  };
}
