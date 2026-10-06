# ADR 0009 — Identity domain: one global user, many identities

* Status: Accepted
* Date: 2026-10-06
* Ticket: SF-19 (foundation for the SF-18 authentication tickets)

## Context

A person can be a fighter, a coach, a gym member, owner or staff, a sponsor
member and SimpleFit staff, all at once. Sign-in methods (email, Google,
Apple, later others) must lead to that one person. Sessions, verification,
profiles and workspaces come later and build on this model.

## Decision

`SimpleFit.Accounts` owns two tables:

```
users       id (uuid), timestamps
identities  id (uuid), user_id → users (ON DELETE CASCADE),
            provider (text), provider_subject (text), timestamps
            UNIQUE (provider, provider_subject)
```

### One global user, no roles on it

* `users` has no role, type, profile, credential or provider columns. Roles
  are separate records (fighter/coach profiles, workspace memberships, staff
  access) owned by their own tickets.
* A user owns any number of identities, including several from the same
  provider (there is no `UNIQUE (user_id, provider)`; a product rule may add
  one later). Each identity belongs to exactly one user.
* Identities are owned by their user (`ON DELETE CASCADE`). The future
  account-deletion lifecycle decides when a user is physically deleted; once
  it is, its sign-in identities are removed with it and never orphaned.

### The identity key

* `{provider, provider_subject}` is unique across SimpleFit and the database
  unique index is the authority, including under concurrency.
* `email`: the subject is the canonical address (below). It is the single
  source of truth: there is no separate email column.
* `google`, `apple`: the subject is the provider's stable account id (the
  `sub` claim), stored exactly as issued (case-sensitive, opaque). An email a
  provider reports is metadata, never the key, and is not stored by SF-19;
  SF-22/SF-23 may add explicitly non-key provider metadata if a requirement
  appears.
* Providers are layered on purpose:
  * **Database:** `provider` is extensible text constrained only by format
    (`^[a-z][a-z0-9_]{0,31}$`), plus `UNIQUE (provider, provider_subject)`.
    It is never a fixed `IN ('email', 'google', 'apple')` list.
  * **Domain:** the supported set is `email`, `google`, `apple`
    (`Ecto.Enum`, stored as text). A new provider (Microsoft, passkeys,
    enterprise SSO) is a code change, not a migration.
* Subjects are printable ASCII without spaces, 1–255 characters (database
  check `provider_subject_format`). This covers the subjects of the current
  providers (canonical email addresses, Google and Apple account ids). A
  future provider whose subjects need Unicode or more than 255 characters
  would require widening or relaxing that storage constraint with a new
  migration; that is a column-level change, not a redesign of the
  User/Identity ownership model.

### Canonical email (`SimpleFit.Accounts.EmailAddress`)

1. Trim surrounding whitespace.
2. Require printable ASCII without inner whitespace: ASCII mailboxes, with
   internationalized domains accepted in punycode (`xn--...`). Unicode
   mailboxes and Unicode domains (EAI) are not accepted.
3. Lowercase the whole address (ASCII), local part included. This is
   SimpleFit's identity policy, deciding which inputs denote the same
   SimpleFit identity; it does not claim that SMTP local parts are
   case-insensitive (RFC 5321 allows them to be case-sensitive).
4. Require structural validity: one `@`; a 1–64 character dot-atom local part
   (no quoted strings, no leading/trailing/double dots); a domain of two or
   more 1–63 character labels (`a-z`, `0-9`, inner `-`); 254 characters at
   most.

No provider-specific rewriting: dots, `+tags` and provider aliases are kept,
because collapsing them could merge different people. The database check
`email_subject_canonical` rejects any non-lowercase email subject, so no code
path can store a case variant.

### Linking and conflicts

* An existing `{provider, subject}` resolves to its user; registration never
  creates a second user for it.
* `register_user/2` creates a user and its first identity in one transaction.
  If the identity exists (or a concurrent registration commits it first), the
  result is `{:error, :conflict}` and the new user row is rolled back.
  Registration stays distinct from resolution: it is never find-or-create.
  Provider sign-in flows (SF-22/SF-23) compose `resolve_user/2`,
  `register_user/2` and `link_identity/3` according to their own
  authentication policy.
* `link_identity/3` attaches an identity to a user the caller has already
  authenticated: idempotent for the same user, `{:error, :conflict}` if
  another user owns it. Identities are never transferred; users are never
  merged.
* **No email-based linking.** A Google or Apple account reporting an email
  that an email identity uses is not linked or merged automatically. A
  verified linking policy, if any, is for SF-22/SF-23 to define on top of
  `link_identity/3`.
* Conflicts carry no information about the owner (no account enumeration).

### Concurrency

The unique index decides races. `register_user/2` does not pre-check: the
losing transaction fails on the index and rolls back. `link_identity/3` looks
the identity up first; if a concurrent insert wins between lookup and
insert, it re-reads the winner and returns what a later caller would get
(`{:ok, identity}` for the same user, `:conflict` otherwise). Tests cover
this on real, separate connections (`test/simple_fit/accounts/race_test.exs`).

### Results and privacy

* `{:ok, value}`, `{:error, :not_found}`, `{:error, :conflict}`, or
  `{:error, %Ecto.Changeset{}}` for an unsupported provider (`invalid_choice`)
  or invalid subject (`invalid_format`, `too_long`, `required`). Expected
  outcomes are returned, never raised, logged at `:error` or sent to Sentry.
* Identities hold no credentials. `provider_subject` is a redacted field, so
  `inspect/2` of identities and changesets never shows an email or provider
  id.

## Out of scope

Sessions and tokens, sign-in/sign-up endpoints, email verification, Google
and Apple token verification (the future `SimpleFit.Identity` provider
boundary, ADR 0004/0005), profiles, workspaces, roles and admin access. No
HTTP surface: the OpenAPI contract is unchanged.

## Consequences

* Every later identity feature reuses one model and one conflict policy.
* Changing a user's email address is not defined yet; whatever flow adds it
  keeps the same uniqueness and canonical-form rules.
* Internationalized email addresses need an explicit policy before they are
  accepted.
