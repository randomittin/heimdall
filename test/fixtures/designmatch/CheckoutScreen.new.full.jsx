// CheckoutScreen.new.full.jsx — the NEW component after a COMPLETE migration.
// Regenerated fresh from the canonical (different layout/styling shape), then
// every behavioral unit from the old component ported and WIRED. The behavioral
// diff over (old, this) must be K=0 with high coverage.
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

  const confirmPurchase = () => {
    onComplete(total);
    navigation.navigate("Receipt", { cartId, total, currency });
  };

  // Fresh canonical-derived layout — different structure from the old file, but
  // every handler/state/api/nav/effect/prop is present and wired.
  return (
    <View style={styles.root}>
      <Text style={styles.total}>{currency + " " + total}</Text>
      <View style={styles.row}>
        <TextInput style={styles.field} value={coupon} onChangeText={setCoupon} />
        <Pressable style={styles.btn} onPress={applyCoupon} disabled={loading}>
          <Text>Apply</Text>
        </Pressable>
      </View>
      <Pressable style={styles.cta} onPress={confirmPurchase}>
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
