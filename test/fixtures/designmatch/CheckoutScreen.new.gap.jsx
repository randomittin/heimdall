// CheckoutScreen.new.gap.jsx — the NEW component with a PLANTED MIGRATION GAP.
// confirmPurchase() is DECLARED (it exists by name — grep would call it migrated)
// but it is NEVER wired to a JSX onPress prop: the Confirm button below has no
// handler. So the purchase-confirm behavior (onComplete + navigation.navigate)
// is NOT actually reachable. The behavioral diff must report:
//   - handler `confirmPurchase`  → UNMATCHED (present in new but UNWIRED)
//   - nav `navigation.navigate`  → UNMATCHED (only reachable from the dead handler)
// K>=1 → tmp-exit BLOCKED. This is the exact grep-false-green this module guards.
import React, { useState, useEffect } from "react";
import { View, Text, TextInput, Pressable, StyleSheet } from "react-native";
import { useNavigation } from "@react-navigation/native";

export default function CheckoutScreen({ cartId, currency, onComplete }) {
  const navigation = useNavigation();
  const [coupon, setCoupon] = useState("");
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let alive = true;
    fetch("/api/cart/" + cartId + "/total")
      .then((r) => r.json())
      .then((data) => {
        if (alive) setTotal(data.amount);
      });
    return function cleanup() {
      alive = false;
    };
  }, [cartId]);

  const applyCoupon = async () => {
    setLoading(true);
    const res = await fetch("/api/coupon/redeem", {
      method: "POST",
      body: JSON.stringify({ code: coupon, cartId }),
    });
    const json = await res.json();
    setTotal(json.newTotal);
    setLoading(false);
  };

  // DECLARED but never bound to any onPress — a dead handler. Its body holds the
  // only navigation.navigate call, so that nav surface is dead too.
  const confirmPurchase = () => {
    onComplete(total);
    navigation.navigate("Receipt", { cartId, total, currency });
  };

  return (
    <View style={styles.root}>
      <Text style={styles.total}>{currency + " " + total}</Text>
      <View style={styles.row}>
        <TextInput style={styles.field} value={coupon} onChangeText={setCoupon} />
        <Pressable style={styles.btn} onPress={applyCoupon} disabled={loading}>
          <Text>Apply</Text>
        </Pressable>
      </View>
      <Pressable style={styles.cta}>
        <Text>Confirm purchase</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { padding: 16 },
  total: { fontSize: 24 },
  row: { flexDirection: "row" },
  field: { flex: 1 },
  btn: { marginLeft: 8 },
  cta: { marginTop: 24 },
});
