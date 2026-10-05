# clean-sample

A correct settlement webhook: events are claimed atomically, the fee is rounded half-up in
integer cents, and balances and settlement records are readable only by their owner.

    hmd attack fixtures/attack/clean-sample --yes         # PROVEN

PROVEN is earned, not defaulted: every attack in the battery runs against it and none
breaks it. `../buggy-webhook` is the same webhook with one defect and is DENIED.
