"""runhmd adapters (RP9): how a claim reaches runhmd.

An adapter turns "some agent (or some human) says this task is done" into three calls, `start`,
`events` and `claim`, whose results runhmd can attack without caring which tool produced them. The
contract, every rule of it and the way it is checked live in docs/ADAPTERS.md; `python3 -m
adapters.conformance --adapter <name>` is its executable form.

Layout: `adapters/<name>.py` is an adapter; `adapters/_*.py` are helpers shared by adapters (never
listed as one); `adapters/conformance/` is the independent suite that grades them.
"""


class AdapterError(Exception):
    """An adapter refused, or could not do, what it was asked: the one exception type the contract allows.

    `kind` is a short snake_case machine code (the contract fixes bad_task, unknown_base, unknown_run
    and unavailable; an adapter may add its own) and `detail` says why in one sentence. Anything else
    that escapes an adapter is a contract violation, not an error handled.
    """

    def __init__(self, kind, detail):
        super().__init__("%s: %s" % (kind, detail))
        self.kind = kind
        self.detail = detail
