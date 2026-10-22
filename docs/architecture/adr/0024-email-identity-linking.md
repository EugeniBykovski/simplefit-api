# ADR 0024 — Verified email identity linking

* Status: Accepted (SF-77, 2026-10-22). Epic SF-48.
* Context: ADR 0009 (identities, `link_identity/3`, no email-based
  linking), ADR 0010 (sessions), ADR 0012 (email challenges), ADR 0019
  (identity security), ADR 0021 (coach invitations bound to verified email
  identities, SF-57/SF-73).

## Problem

A coach invitation reaches its recipient only through an **email identity**
of the recipient (`Accounts.verified_email_addresses/1`, ADR 0021). A user
who signed up with Google or Apple has no email identity: the email a
provider reports is never stored or trusted (ADR 0009, 0013, 0014). So an
invitation sent to that person's address can never reach their existing
account, and creating a second account by email registration would split
their profiles.

## Decision

A signed-in user can add an email identity to **their own** user after
proving control of the mailbox with a one-time code entered in the same
session. Nothing else changes.

```
GET  /api/v1/me/email-identities                  listMyEmailIdentities
POST /api/v1/me/email-identities/link-challenge   requestMyEmailIdentityLink {email}   → 202
POST /api/v1/me/email-identities/confirm-link     confirmMyEmailIdentityLink {email, code} → 200
```

All three are `:authenticated` (bearer access token, live session,
`no-store`). The user and session come from the token; no user or identity
id is accepted.

### Domain ownership: the existing machinery

* **Identity:** the result is an ordinary `Identity{provider: :email,
  provider_subject: <canonical address>}` of the current user. No new table,
  model or provider. `{provider, provider_subject}` stays unique across
  SimpleFit (the SF-19 unique index), so one address has at most one owner.
* **Challenge:** a third purpose, `identity_link`, of `email_auth_challenges`
  (`SimpleFit.Accounts.EmailAuth`): the same 6-digit codes, keyed verifiers
  bound to purpose and challenge id, 10-minute expiry, 5 wrong codes per
  challenge, row locks and cleanup as ADR 0012. A link challenge also
  stores `user_id` and `session_id` (both `ON DELETE CASCADE`) and never a
  registration token or session (`purpose_fields` check).
* **Normalization:** `EmailAddress.normalize/1` (ADR 0009), unchanged: trim,
  ASCII lowercase, dots and `+tags` kept, no provider alias collapsing,
  Unicode addresses refused. The same canonical string is the challenge
  target, the identity key and the invitation recipient digest input.

### Lifecycle

1. **Request.** Validate and normalize; rate limit; in one transaction,
   supersede the user's open link challenge (any address), insert the new
   one and enqueue its email. One open link challenge per user
   (`email_auth_challenges_one_open_link_index`); registration and sign-in
   keep one open challenge per address. Two users can therefore never
   supersede each other's challenge for the same address.
2. **Confirm.** Validate and normalize; per-client verify limit; then in one
   transaction:
   1. `FOR KEY SHARE` the user row, then `FOR SHARE` the session row, and
      require the session to be the caller's, not revoked and not expired.
      This is the order in which deleting a user locks them, so a racing
      logout, revocation or account deletion either commits first (the link
      is refused, `unauthorized`) or waits until the link has committed;
      never a deadlock.
   2. `FOR UPDATE` the user's latest link challenge. Missing, closed or
      expired → `code_expired`. Requested in another session of the same
      user → `code_expired` (no attempt counted: the session that asked must
      answer, like a registration code).
   3. Another address, or a wrong code → `code_invalid`, counted; the fifth
      closes it (`exhausted`).
   4. `INSERT … ON CONFLICT DO NOTHING` the email identity for the user, and
      read the owner back. The unique index decides a race with another
      link or an email registration of the same address; the insert waits
      for the competing transaction.
      * The caller's → challenge `code_verified`; `linked` (new) or
        `already_linked` (it already was; nothing duplicated).
      * Another user's → challenge `conflict`; `409 conflict`. Nothing is
        moved, merged or signed in.

A successful confirmation creates no user, session, relationship or
invitation response. Existing Google and Apple identities and sessions are
untouched.

### Security decisions

* **Two independent facts.** The live session establishes the user; the
  code establishes mailbox control. Neither is enough alone: an invitation
  token is not mailbox proof (it still answers
  `invitation_recipient_mismatch`), a provider email claim is never read,
  and a code is bound to one user, one session, one address and one purpose.
* **Session binding.** No recent-authentication policy exists in SimpleFit
  (ADR 0019 lists none), so none is invented. The challenge is bound to the
  session that requested it, and a revoked, expired or deleted session can
  neither request nor confirm. This is stricter than requiring only "some
  valid session of the user".
* **Purpose separation.** Verifiers bind the purpose (`sfec1 … identity_link
  …`): a link code never verifies a registration or sign-in challenge and
  vice versa. A link never issues a session (`purpose_fields` check:
  `session_created_at IS NULL`).
* **Enumeration.** The request answers `202` with the same body for every
  well-formed address, whether it is new, the caller's or another user's,
  and always sends the code: there is nothing to infer from the answer,
  timing of enqueueing, expiry or attempt handling. Whether the address can
  be linked is answered only to the holder of the correct code: `conflict`
  (generic envelope, no detail about the owner). That holder controls the
  mailbox and could learn the same by requesting an email sign-in code, so
  revealing it after proof adds no oracle (the rule ADR 0012 applies to
  `verified_elsewhere` and `conflict`).
* **Consequence: a new sign-in method.** An email identity signs in (ADR
  0009/0012). After linking, the address also signs in to the same user with
  an E17 code, and registration for it creates nothing (decoy). This is the
  canonical identity model, not a side effect, and requires the same mailbox
  control as the link.

### Abuse limits

PostgreSQL fixed windows (`SimpleFit.RateLimit`, ADR 0019), HMAC keys:

| Operation | Limit | Key |
| --- | --- | --- |
| Request a link code | 1 / 1 min, 5 / h, 10 / day | user (any address, any session) |
| Request a link code | 1 / 1 min, 5 / h, 10 / day | address (`identity_link_request:*`, any user) |
| Request a link code | 20 / 10 min | client, shared with every code request |
| Confirm | 60 / 10 min | client, shared with every code verification |
| Confirm | 5 wrong codes | challenge |

Requesting again or switching address or session never adds attempts
beyond the per-user windows: at most 10 challenges × 5 guesses per user per
day against a 10⁶ code space.

### Email

`SimpleFit.Email.Templates.email_link_code/1`: subject "Your SimpleFit email
verification code: {code}", the code, its expiry, "never share", and "Didn't
ask for this? … Without the code, the address isn't added to any account."
No link, token, account data or personal data. Sent through
`SimpleFit.Email.deliver_later/1` in the challenge transaction (encrypted
Oban payload, `JobLogger` outcomes only). It has no Claude Design artboard
yet (ADR 0011 amendment).

### Observability

`[:simple_fit, :auth, :email, :requested | :sent | :verified | :rejected |
:rate_limited]` with `purpose: :identity_link` and bounded metadata only
(`outcome: :accepted | :queued | :linked | :already_linked`, `channel:
:code`, `reason: :code_invalid | :code_expired | :conflict |
:unauthorized`). Queries carrying addresses, digests or verifiers run with
`log: false`. The SF-29 canary sweep covers the three endpoints.

### Invitations (SF-57, SF-73)

No invitation code changed. The linked address is returned by
`Accounts.verified_email_addresses/1`, so the SF-73 inbox, the id-based
preview/accept/decline and the SF-57 token recipient check recognise it
immediately. Every acceptance requirement still applies: completed account
registration, completed fighter profile, the approved disclosure version and
language, 18+, explicit acceptance and the sharing gate. With sharing off,
the inbox and responses stay `404`.

## Alternatives rejected

* **Trust the provider's verified email claim.** Rejected by ADR 0009: a
  claim is not SimpleFit's proof, and Apple's relay addresses make it
  unreliable anyway.
* **Register a separate email account and merge.** No merging exists by
  design; it would also move profiles and relationships between users.
* **A separate linking table or service.** The identity and challenge
  models already carry every invariant needed.
* **Per-address one-open challenge for links.** Lets any user cancel
  another user's pending link for the same address.

## Consequences and follow-ups

* Web and mobile UIs (an "Add email" flow in account settings, and a
  prompt from the empty inbox) are follow-up tickets; they need a Claude
  Design artboard for the email and screens.
* No identity removal (unlinking) exists; a user cannot drop an email
  identity yet.
* Account deletion does not exist yet; the cascades and lock order above
  already make it safe for this flow.
* `CoachInvitation` per-recipient limits are unchanged; linking does not
  resend or alter invitations.

## Tests

* `test/simple_fit/accounts/email_identity_link_test.exs`: matrix A–D, F–K,
  P, Q, T; purpose separation, normalization, supersession, limits, deletion,
  cleanup, privacy of logs, jobs and telemetry.
* `test/simple_fit/accounts/email_identity_link_race_test.exs` (real
  connections, outside the SQL sandbox): concurrent confirmations, two users
  racing for one address, a link racing an email registration, logout and
  account deletion racing a confirmation, concurrent requests, a 30-guess
  burst, refresh rotation (S).
* `test/simple_fit_web/controllers/email_identity_controller_test.exs`: the
  HTTP contract and Journeys 1, 2, 5, 6 with real Google/Apple sign-in
  (provider email claims ignored, N, R), SF-57 token and SF-73 id acceptance,
  legal and onboarding gates, sharing off.
