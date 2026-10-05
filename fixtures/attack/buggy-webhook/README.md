# buggy-webhook

A settlement webhook that looks done: it deduplicates redelivered events, every test that
delivers an event twice in a row passes, and it reads cleanly. It has one real defect.

    hmd attack fixtures/attack/buggy-webhook --yes        # DENIED

`hmd attack` finds that a provider retry arriving within 50ms of the first delivery
credits the account twice (the event is marked processed only after the account is
credited), and prints the minimal counterexample. `../clean-sample` is the same webhook
with the claim made atomic: it is PROVEN.
