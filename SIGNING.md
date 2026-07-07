# Release Signing — the auto-update trust root

Heimdall clients **auto-update themselves** (`bin/heimdall-autoupdate`, on by default): on
SessionStart they compare the installed version to the latest GitHub Release and, if newer,
re-run that release's `install.sh` in the background. That is a direct code-execution channel
to every installed machine. **Signing is what stops a compromised release channel (a hijacked
GitHub account, a MITM, a malicious mirror) from pushing arbitrary code to the entire fleet.**

The guarantee, in one line:

> An auto-updating client applies a release **only** if its `install.sh` carries a `minisign`
> signature that verifies against the public key **shipped in this repo**
> (`release/heimdall-signing.pub`). Unsigned, tampered, or wrong-key releases are **refused**;
> the client stays on its current, verified version and says so loudly.

---

## Why minisign

- **Tiny, no infrastructure.** One static binary (`brew install minisign`), Ed25519, a 2-line
  public key. No PKI, no keyservers, no Sigstore/cosign/OIDC dependency, no CA to run.
- **Detached signatures.** The signature is a separate `install.sh.minisig` asset on the Release;
  the artifact clients fetch (`install.sh`) is unchanged.
- **Verifiable without the binary.** We also ship a bundled pure-python verifier
  (`bin/lib/minisign_verify.py`) so a client that has `python3 + cryptography|pynacl` (already a
  heimdall dependency) verifies even without the `minisign` binary installed. If **neither** a
  `minisign` binary nor a python crypto backend exists, the client **fails closed** (refuses).

## The trust model

- **Public key ships in the repo:** `release/heimdall-signing.pub`. This is the trust anchor.
  The updater reads the **local, already-installed** copy — never a key downloaded next to the
  artifact (that would let an attacker ship their own key alongside malicious code).
- **Secret key never touches the repo.** RJ holds it outside the tree
  (default `~/.heimdall/signing/heimdall-signing.key`, `chmod 600`). It is never committed,
  never printed, never uploaded.
- **Verify-then-run the same bytes.** The updater downloads `install.sh` to a temp file,
  verifies that exact file, and executes *that* file — no re-fetch between check and run (no TOCTOU).

## Components

| Piece | Role |
|---|---|
| `release/ship.sh` → `sign_release_artifact` | After publishing the Release, signs `install.sh` and uploads `install.sh.minisig` as a Release asset. No key / no minisign ⇒ **WARN + release UNSIGNED** (never hard-blocks RJ). |
| `release/heimdall-signing.pub` | The in-repo public key (trust anchor). **Committed by RJ** as part of key generation (see below). |
| `bin/lib/heimdall-verify.sh` | `heimdall_verify_release <artifact> <sig> <pubkey>` — minisign binary, else the bundled python verifier. Distinct refusal codes. |
| `bin/lib/minisign_verify.py` | Bundled pure-python minisign verifier (Ed25519 via cryptography/pynacl). |
| `bin/heimdall-autoupdate` → `apply_update` | Downloads artifact + sig, **verifies before executing**. Any failure ⇒ refuse + stay + loud message + `autoupdate.log` line. |

Verifier refusal codes (`heimdall_verify_release`): `0` valid · `2` missing signature (cardinal:
unsigned is not applied) · `3` missing public key (no trust root) · `4` missing artifact ·
`5` no verifier available · `6` invalid signature (tampered / wrong key / corrupt).

---

## ⚠️ Launch ordering (READ THIS FIRST)

The verifying updater is **fail-closed**: with no `release/heimdall-signing.pub` present it
refuses every update (code `3`, no trust root). Therefore the public key **must ship in the same
release that first carries the verifying updater**, or auto-update halts for the fleet.

**So, at launch week, before the first release that includes this updater:**
1. Generate the keypair (command below) — this writes `release/heimdall-signing.pub`.
2. **Commit** `release/heimdall-signing.pub`.
3. Ship normally (`release/ship.sh`) — the Release now carries both the verifying updater **and**
   its trust anchor, and `ship.sh` attaches the signature.

Older clients (running the pre-signing updater) apply that release with their *old* logic; from
then on every client verifies. Fix-forward and the un-publish kill-switch still work as documented
in `docs/analysis/launch-autoupdate-posture.md`.

---

## One-time key generation (RJ — launch-week action)

Run this **once**, from the repo root. `-W` makes a **passwordless** secret key so `ship.sh` can
sign non-interactively; the key sits outside the repo at `chmod 600`.

```sh
mkdir -p ~/.heimdall/signing && chmod 700 ~/.heimdall/signing
minisign -G -W -f \
  -s ~/.heimdall/signing/heimdall-signing.key \
  -p release/heimdall-signing.pub
chmod 600 ~/.heimdall/signing/heimdall-signing.key

git add release/heimdall-signing.pub
git commit -m "feat(signing): add release signing public key (trust root)"
```

Then back up `~/.heimdall/signing/heimdall-signing.key` somewhere safe and offline (a password
manager / hardware-backed store). **Losing it means you can no longer sign releases** (you must
rotate — see below). **Leaking it means an attacker can sign malicious releases** — rotate at once.

> Hardening option: omit `-W` to password-protect the secret key. Then `ship.sh` signing becomes
> interactive (minisign prompts for the password each release), so only do this if you sign by
> hand. The launch default is the passwordless key + 0600 perms outside the repo.

## Shipping a signed release

Set the key location if it is not the default, then ship as usual:

```sh
export HEIMDALL_SIGNING_KEY=~/.heimdall/signing/heimdall-signing.key   # optional; this is the default
release/ship.sh                 # bump → scan → push → R9 → tag → Release → SIGN + upload sig
```

After the Release is published, `ship.sh` signs `install.sh` and uploads `install.sh.minisig`.
If `minisign` or the key is missing it **warns and releases unsigned** (and prints the exact
re-sign command) rather than blocking you.

Sign an already-published release by hand:

```sh
minisign -S -s ~/.heimdall/signing/heimdall-signing.key -m install.sh -x install.sh.minisig
gh release upload vX.Y.Z install.sh.minisig --clobber
```

## Verifying a release by hand

```sh
gh release download vX.Y.Z -p install.sh -p install.sh.minisig
minisign -Vp release/heimdall-signing.pub -m install.sh -x install.sh.minisig
# or, without the minisign binary:
python3 bin/lib/minisign_verify.py --pubkey release/heimdall-signing.pub \
  --artifact install.sh --sig install.sh.minisig && echo OK
```

## Key rotation

Rotate on suspected compromise, on schedule, or when the key holder changes:

1. Generate a **new** keypair (same command, new files if you want to keep the old for reference).
2. **Commit the new `release/heimdall-signing.pub`.** This is the cut-over: because clients read
   the *local* public key, they only start trusting the new key after they have installed a release
   built with it. So ship **one bridge release signed by the OLD key** that carries the NEW public
   key; clients apply it (old key still verifies), and from the *next* release the new key is in force.
3. Ship subsequent releases signed by the new key.
4. If the old key was **leaked**, also un-publish/delete any releases an attacker might have signed
   with it, and treat the incident per the posture memo's kill-switch section.

## Threats this stops (and does not)

- **Stops:** a swapped/backdoored `install.sh` on the Release, a release with no signature, a
  signature made by any key other than the trusted one — all refused before `bash` runs.
- **Does not stop:** a leaked secret key (rotate), or a malicious commit that is *legitimately*
  signed and shipped by RJ (that is what R9 + code review + the green-gate ritual are for).
  Signing authenticates the *channel*, not the *intent* of the release author.
