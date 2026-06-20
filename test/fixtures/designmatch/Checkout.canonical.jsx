// Checkout.canonical.jsx — the CANONICAL design source (web React/JS).
// This is the design-of-record for the Checkout screen: VISUAL only, no behavior
// (no handlers, no state, no API/nav). designmatch v2 regenerates the RN
// component FROM this file via the language seam, then migrates behavior back in
// from the quarantined old RN component. Editing any non-whitespace byte here is
// a "design change" the hash-log detects (triggering a regenerate).
export default function Checkout() {
  return (
    <div className="screen">
      <h1 className="total">Total</h1>
      <div className="row">
        <input className="coupon" aria-label="Coupon" />
        <button className="apply">Apply coupon</button>
      </div>
      <button className="cta">Confirm purchase</button>
    </div>
  );
}
