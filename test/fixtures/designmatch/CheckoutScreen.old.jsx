// CheckoutScreen.old.jsx — the OLD component: visual + behavioral.
// This is the SOLE source of the screen's behavior in designmatch v2. Its
// behavioral surface (handlers, state, API, nav, effect, props) is what the
// regenerated NEW component must recover before the old file leaves tmp.
import React, { useState, useEffect } from "react";
import { View, Text, TextInput, Pressable } from "react-native";
import { useNavigation } from "@react-navigation/native";

export default function CheckoutScreen({ cartId, currency, onComplete }) {
  const navigation = useNavigation();
  const [coupon, setCoupon] = useState("");
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);

  // effect: load the cart total on mount / when cartId changes.
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

  // handler: apply a coupon via the data API, then update total.
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

  // handler: confirm purchase, then navigate to the receipt screen.
  const confirmPurchase = () => {
    onComplete(total);
    navigation.navigate("Receipt", { cartId, total, currency });
  };

  return (
    <View>
      <Text>{"Total: " + total + " " + currency}</Text>
      <TextInput value={coupon} onChangeText={setCoupon} accessibilityLabel="Coupon" />
      <Pressable onPress={applyCoupon} disabled={loading}>
        <Text>Apply coupon</Text>
      </Pressable>
      <Pressable onPress={confirmPurchase}>
        <Text>Confirm purchase</Text>
      </Pressable>
    </View>
  );
}
