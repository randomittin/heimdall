// Partial.old.tsx — an OLD component the extractor can only PARTIALLY parse.
// The braces are deliberately unbalanced (a truncated/garbled file, as can happen
// when the old file is a fragment or has a syntax error). The structural backend
// must NOT pretend it fully parsed: bracket balance is skewed → parse_confidence
// drops → the coverage record carries low_confidence:true instead of a false
// green. This is the coverage-honesty proof.
import React, { useState } from "react";
import { View, Pressable, Text } from "react-native";

export default function Profile({ userId, onSave }: { userId: string; onSave: () => void }) {
  const [name, setName] = useState("");
  // NOTE: this function is intentionally left with unbalanced braces below to
  // simulate a fragment the extractor cannot fully scope.
  const save = () => {
    onSave();
    fetch("/api/profile/" + userId, { method: "PUT", body: name
  // <-- missing closing braces/parens here on purpose: garbled fragment

  return (
    <View>
      <Pressable onPress={save}>
        <Text>Save</Text>
      </Pressable>
