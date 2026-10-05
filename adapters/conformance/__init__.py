"""The adapter conformance suite (RP9): the contract in docs/ADAPTERS.md, as checks.

    python3 -m adapters.conformance --adapter <name>     exit 0 only when the adapter meets every rule

The suite is authored independently of the adapters it grades: its expectations come from the contract
and from its own fixture repository, never from an adapter's behaviour (see test/adapter-conformance.test.sh
for the proof that it can fail). Adapter-specific glue is confined to drivers/.
"""
