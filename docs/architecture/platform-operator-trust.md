# Platform operator trust model (SF-107)

**Status: PROPOSED.** Satisfies the requirements SF-136 set for SF-110
([ADR 0026, "Enabling production review"](adr/0026-gym-domain-architecture.md)). **Nothing is built
and no grant exists.** No operator should be created until this is approved and SF-110 is reviewed.

## 1. What an operator is

An authority boundary for acting on behalf of SimpleFit. It isn't a profile, a workspace role or a
user attribute.

| Property | Rule |
| --- | --- |
| Identity | One active operator row per global user. Same `users` row; no separate account |
| Immutable actor | `platform_operators.id` is the actor recorded forever. A revoked person who returns gets a new row |
| Source | The bootstrap ceremony once, then `operators.manage` |
| Proof on each request | Valid session, active operator, a current key check on that session, and an active grant for that permission |
| Default | Deny. No permission without a row |
| Registry capability | `ADMIN` means "has an active operator row". It isn't a permission |

## 2. Lifecycle

| State | Meaning | Allowed | Next |
| --- | --- | --- | --- |
| `pending_enrollment` | Created; no key yet | `/admin/verify` enrollment only. No data | `active`, `revoked` |
| `active` | Working | As granted | `suspended`, `revoked` |
| `suspended` | Temporarily stopped | Nothing | `active`, `revoked` |
| `revoked` | Finished. **Terminal** | Nothing | — |

* Enrollment expires. An unenrolled operator is revoked by a job.
* Suspending or revoking takes effect on the next call: there is no cache, and it ends the
  operator's step-ups in the same transaction.
* The last active holder of `operators.manage` can't be suspended or revoked through the API.
* Every change names an actor, a reason and an `operation_id`.

## 3. Authentication assurance

| Level | Means | Needed for |
| --- | --- | --- |
| A0 | Ordinary session | Nothing in the console |
| A1 | Session plus security key check, within limits | All reads |
| A2 | A1 with a key check in the last 5 minutes (proposed) | High-risk actions |

* **Credential:** WebAuthn hardware key. Requires user verification. Synced passkeys refused where
  attestation allows it, as AD0 says ("phone passkeys are not accepted").
* **At least two keys** enrolled for each operator, one as a backup.
* **Bound to the session.** A step-up belongs to one `sessions.id`. Sign-out, refresh-reuse detection
  (ADR 0010) or revocation ends it.
* **Limits (proposed, from AD0):** 30 minutes idle, 8 hours absolute.
* **Not in MVP:** VPN or device checks and SSO. They need infrastructure that doesn't exist. AD0's
  Okta path stays FUTURE ([D-SA15](sponsor-admin-decision-register.md)).
* **New dependency:** a WebAuthn library needs an evaluation under the dependency rules. Verifying
  signatures by hand isn't an option.

Why not an identity provider first: it adds a vendor, cost and an administrator role for a team that
may be one person. SF-136 accepts either, and the authority interface doesn't change if one comes later.

## 4. The authority

```elixir
# Proposed shape. Same contract as VerificationAuthority (SF-136).
SimpleFit.Operators.authenticate(credential, permission, assurance)
  :: {:ok, %Principal{operator_id, user_id, authority: :platform_operator}}
   | {:error, :unavailable | :unauthenticated | :step_up_required | {:forbidden, :operator}}
```

* A credential is the request's verified session and step-up. A struct built by hand opens nothing.
* Reads the database on every call with no cache. Callers ask again after taking their locks.
* `Gyms.VerificationAuthority` gets a backend that delegates here, replacing the production compile
  guard in one reviewed change that also adds `platform_operator` to `operator_authority` by
  migration. Until then `Disabled` stands, and **there is no interim switch**.
* Mix tasks gain no authority. `mix gyms.verification` stays refused in production. The privileged
  billing commands get a separate review: they run from a shell, where no session or key exists.

## 5. Founder bootstrap

**Do not implement in SF-107.** A one-time procedure with independent authorization, explicit
identity binding and an audit trail.

### Rejected

| Option | Why not |
| --- | --- |
| First registered user | Anyone can win that race |
| Hardcoded email in code | An email string proves nothing; and repo readers see it |
| `ADMIN_EMAIL` in the environment | Anyone with config access grants anything; email isn't identity |
| `mix operator.grant --email` | Exactly what SF-136 removed |
| Admin choice in onboarding | Self-assertion |
| Hand-written SQL | No attribution, no constraints, no evidence |
| Seeds or migration data | Runs on every environment; ties a person to code |

### Proposed ceremony

Binds three independent things: **a reviewed public key** (authorization), **a signed statement
naming a user id** (decision), and **the person's own session and hardware key** (identity).

```
1. PREPARE (reviewed code)
   Offline, on a clean machine, generate an Ed25519 keypair. Private key stays offline.
   A reviewed PR adds the public key as a compile-time constant for production.
   Without it, the ceremony code answers :unavailable. No env var can supply it.

2. ACCOUNT (the person, in the product)
   The founder signs in normally, with a verified identity and completed registration.
   They read their own user id from GET /api/me.

3. SIGN (offline)
   A statement is signed: { purpose: "bootstrap", environment, user_id, permissions: [...],
   ceremony_id, not_after (under 1 hour) }. Nothing here is an email address.

4. EXECUTE (production release command, by whoever holds deploy access)
   A release function reads the statement from a file: no argument names a person.
   In one transaction, under an advisory lock, it checks:
     signature, environment, expiry and unused ceremony_id
     no operator row has ever existed
     the user exists, has a verified identity and completed registration
   Then it writes: the operator as pending_enrollment with bootstrap = true, one assignment row per
   permission, and an audit event carrying the ceremony id and the statement's hash.

5. ENROLL (the person, in the browser)
   The founder signs in, opens /admin/verify and enrolls two hardware keys, in their own session,
   before the short expiry. Only then is the operator active.

6. CLOSE (reviewed code)
   A second PR removes the public key and ceremony code from production.
   A partial unique index on bootstrap = true keeps a second bootstrap impossible regardless.

7. EVIDENCE
   Record outside the app: who did each step and when, PR links, statement hash, and any witness.
```

**The founder's permissions are explicit rows**, listed in the signed statement. There's no
`superuser` value. Broad authority stays visible and each row is individually revocable.

### What this does and doesn't prove

| Attack | Result |
| --- | --- |
| Registers first, or as admin | Nothing happens; no path exists |
| Sets an email in config | Nothing reads one |
| Reruns the command | Refused: an operator has existed, `ceremony_id` used, unique index |
| Steals only the signed statement | Needs production execution, and the target's session and keys |
| Compromises only a founder session | Can't enroll without the operator row, or act without a key |
| Has production shell plus the private key | Can bootstrap. That's why the key is offline and the code is removed |
| Has production database write | **Can change any row.** No application check stops this; it needs database roles and infrastructure controls that don't exist yet |

**Solo limit, stated plainly:** if one person holds every step, the ceremony binds an identity and
leaves evidence, but it isn't separation of duties. A witness helps; it doesn't replace a second
person. See [D-SA13](sponsor-admin-decision-register.md).

### After bootstrap: adding and removing operators

| Step | Rule |
| --- | --- |
| Add | Holder of `operators.manage`, at A2, names an existing user with a verified identity, then lists permissions and a reason. Creates `pending_enrollment` |
| Accept | That person enrolls their own keys in their own session. Nobody enrolls for them |
| Grant more | Row per permission, with reason, optional expiry. **No self-grant**, by a check in code and at the database, except rows from the bootstrap |
| Remove | Revoke a permission or the operator, at A2, with a reason. Effective on next call |
| Offboarding | Revoke the operator. Their user stays. History stays |
| Lookup | By verified email, searched exactly, audited |

## 6. Separation of duties

| Rule | Enforced by |
| --- | --- |
| No self-grant of permissions | Constraint plus code |
| No review of own business | Conflict check by user id, under the lock (SF-136) |
| Audit readable, never writable | Trigger; no update path |
| Operator manager isn't automatically a reviewer | Separate permissions |
| Appeal reviewer differs from original (AD11) | FUTURE, with appeals |
| Two-person approval (AD9, AD10, AD20) | **FUTURE.** Operations that need it are out of the MVP |

**F8 in practice.** The conflict rule is right, and it means a founder who runs a gym can't approve
that gym. With one operator, that gym can't be verified. **A second operator must be named before
that matters** ([D-SA14](sponsor-admin-decision-register.md)). The check must not be relaxed.

## 7. Emergency access and recovery

| Situation | Proposal |
| --- | --- |
| Break-glass (AD20) | **No MVP.** It needs paging, a DPO and a CTO. Standing "emergency full access" is an unbounded backdoor. FUTURE, with an approved process |
| Lost one key | Other key, then enroll a replacement. Audited |
| Lost all keys, other operators exist | An operators manager revokes and re-adds |
| Last operator lost all keys | **Recovery ceremony:** the bootstrap steps again, with a new reviewed public key, statement `purpose: "recovery"` and a separate check that exactly that operator is the last manager. Old row revoked. Not automated, and slow on purpose |
| Compromised operator | Any manager suspends at once. All step-ups end. Audit shows what they did |
| Compromised signing key | Key isn't in production after step 6. During the window: revert the PR |
| Provider, Stripe or email outage | Operator access doesn't depend on them |

## 8. Audit requirements

Every operator **read of non-public data**, every write and every refused attempt, in one
transaction with the action where there is one.

| Field | Note |
| --- | --- |
| `operator_id`, `user_id`, `authority` | Immutable actor. Never an email |
| `permission`, `action` | What was used and done |
| `target_type`, `target_id` | Id only |
| `reason_code`, `ticket_ref` | Required on writes. Free text stays out of audit |
| `operation_id`, `correlation_id` | Idempotency and tracing |
| `session_id`, `ip_digest` | For investigation |
| `outcome` | `allowed` or `refused` plus reason |
| `occurred_at` | Server time |

* **Append-only**, enforced by a trigger (as `gym_audit_events`), with no foreign keys so events
  outlive their targets.
* **AD14's claims aren't real yet:** "hash-chained", "signed export" and "retained 7 years" are
  design statements. Hash chaining and external copies are FUTURE and retention is undecided
  ([D-SA18](sponsor-admin-decision-register.md)).
* Refused-attempt logging is rate limited, so it can't be used to fill the table.

## 9. What SF-110 must deliver

| SF-136 requirement | Here |
| --- | --- |
| Verify a credential cryptographically or through an independent provider | WebAuthn, §3 |
| Enroll and revoke independently of the reviewer | §5, `operators.manage` is a separate permission |
| Current grants on every call, under a documented lock | §4 |
| Immutable actor id and user id | §1, §4 |
| Implement the `VerificationAuthority` behaviour | §4 |
| New `operator_authority` value by reviewed migration | §4 |
| Replace the production compile guard for exactly that backend | §4 |
| Remove `Local` from any path a production build can reach | Already not compiled there; keep it so |
| Security suite against the real authority | [Threat model](sponsor-admin-threat-model.md#3-required-tests) |
