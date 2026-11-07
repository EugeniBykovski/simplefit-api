# Sponsor & Admin — threat model (SF-107)

**Status: PROPOSED.** These are design requirements. Nothing is built, and no case has run. High-risk
operations fail closed: if any check can't run, the answer is no.

## 1. Enforcement layers

| Layer | Holds | Doesn't hold |
| --- | --- | --- |
| Authentication | Who the session belongs to; the key check | Anything about permission |
| Contextual authorization | Membership or operator grant, read fresh | Client state |
| Domain transaction | Locks, state, conflicts, attribution | Direct database writes |
| Database | Transitions, uniqueness, append-only, attribution | A superuser |
| Audit | Evidence of each privileged action | Prevention |
| Monitoring | Detection | Nothing until wired up and watched |

## 2. Threats

| # | Threat | Attack | Controls | Layer |
| --- | --- | --- | --- | --- |
| T1 | Self-registration as Admin | Sign up, pick Admin, call `/admin` | No admin intent exists. Operators come only from the ceremony or `operators.manage`. 404 for non-operators | AuthZ, DB |
| T2 | Sponsor auto-approval | Claim a high budget or tweak requests | Only an operator transition reaches `approved`. No rule engine. Trigger refuses others. Approve endpoint ignores all client state | Domain, DB |
| T3 | Sponsor approval read as operator | Approved sponsor opens `/admin` | Separate tables and checks; no path between them | AuthZ |
| T4 | Operator email impersonation | Register `ewa@simplefit…`, or put an email in config or a flag | Email is never authority. Operators bind to `user_id`. Nothing reads a configured email | AuthN, AuthZ |
| T5 | Privilege escalation | Grant self; edit own grants; forge `permission` | No-self-grant check in code and database. Catalog CHECK. `operators.manage` at A2. Reviewer sets hold no operator permissions | Domain, DB |
| T6 | Bootstrap abuse | Rerun, replay or forge | Reviewed key, signed statement, partial unique index, `ceremony_id`, expiry. [See trust](platform-operator-trust.md#5-founder-bootstrap) | DB, process |
| T7 | Cross-Sponsor access | A member of X requests Y's id | Every query joins an active membership for the path id. Not found, same answer as unknown | AuthZ |
| T8 | Cross-Gym access | Operator or member uses another gym's id | Existing gym rules. Operator gym views expose no member data | AuthZ |
| T9 | Stale session permissions | Removed member keeps a tab open | No permission in tokens or client cache; read per request | AuthZ |
| T10 | Revoked operator | Revoked mid-action | Authority asked again after locks. Step-ups ended in the revocation transaction | Domain, DB |
| T11 | Unauthorized documents | Guess a key; reuse a link; another applicant's file | Keys unguessable, private bucket, per-request permission, 5-minute link, audit. Applicants see only their own | AuthZ, storage |
| T12 | Forged approval | Hand-built principal; client-sent operator id | Principal comes only from the authority. Request bodies carry no actor. Credential checked per call | AuthZ |
| T13 | Conflicting decisions | Two operators, or operator and applicant | Row lock, `expected_revision`, trigger. One wins, the other gets 409 | Domain, DB |
| T14 | Self-review | Operator approves own organization or gym | Conflict check by user id under lock. No override. Includes applicant, members, invited and gym parties | Domain |
| T15 | Account switching | Second user on the same browser sees the first's state | Caches cleared on session boundary (SF-28). Step-up bound to session | Client, AuthN |
| T16 | Session theft | Stolen token reaches the console | Token alone gives A0: no data. A1 needs a hardware key. A2 re-prompts. Refresh reuse revokes (ADR 0010). Short idle window | AuthN |
| T17 | Stolen key | Physical theft | User verification, second operator can revoke, audit | AuthN, process |
| T18 | Audit tampering | Edit or delete a row | Trigger, no update path, no FK cascade. **A database superuser can still tamper:** hash chain and external copy are FUTURE | DB |
| T19 | Privileged API enumeration | Probe `/admin/*`, ids, emails | Uniform 404 for non-operators, UUIDs, exact-only search, rate limits, per-operator limits | AuthZ, rate limit |
| T20 | Data leakage in responses | Overbroad JSON, metadata, logs | Explicit views. Exact-keys and canary tests. Observability allow-lists (ADR 0008). No names or emails in audit or logs | API |
| T21 | Applicant data seen by the wrong party | Internal notes in applicant DTO; budget in public | DTO allowlists. Separate operator and applicant views. Test both | API |
| T22 | Untrusted uploads | Malware; SVG with script; huge files; wrong type | Presigned, private. Type and size allowlist: PDF, PNG, JPEG. **SVG refused or sanitized and never served inline.** Size limit. Scan before an operator can download, `pending` unavailable. Attachment disposition. Per-user limits | Domain, storage |
| T23 | File scanner absent | No scanner exists today | **BLOCKED:** applications with uploads need one, or MVP ships without uploads ([D-SA09](sponsor-admin-decision-register.md)) | Process |
| T24 | CSRF | Cross-site request to a write | API uses bearer tokens in a header. Cookie only on refresh endpoints (ADR 0010). WebAuthn binds origin | AuthN |
| T25 | Replay | Reuse a decision or assertion | `operation_id` unique. WebAuthn challenge single use, sign count checked | Domain, AuthN |
| T26 | Brand impersonation | Applying as a known brand | Reviewer checklist. Work email unverified and labelled so. No public display in MVP | Process |
| T27 | Application spam | Bots filling the queue | Account and registration first, one current application, rate limits | Domain |
| T28 | Malicious text | Script or links aimed at reviewers | Plain text only, escaped, links not auto-activated | UI |
| T29 | Message abuse | Operator message as phishing | Fixed reason codes, plain text, sent only to the applicant | Domain |
| T30 | Invitation hijack | Forward the link | Token hash, bound to verified recipient email, single use, expiry, uniform failures. `owner` never invitable | Domain, DB |
| T31 | Insider browsing | Operator reads for curiosity | Masked by default, reason required, each view audited. No private data endpoint. Audit review needs an owner | Audit, process |
| T32 | Lockout | Last operator lost or revoked | Last-manager rule, two keys, recovery ceremony | Domain, process |
| T33 | Fixture authority in production | `Local` in a prod build | Compile guard kept. Only a reviewed value is added. Production fixture attribution counts as nothing | Build, DB |
| T34 | Placeholder pages | Non-operator sees the admin map | 404 gate before real data ([route matrix](sponsor-admin-route-matrix.md#3-proposed-routes)) | UI, API |
| T35 | Production database access | Direct `UPDATE` | **Not addressed by the app.** Needs database roles and infrastructure controls ([D-SA28](sponsor-admin-decision-register.md)) | Infrastructure |

## 3. Required tests

Each implementing task must have these on real commits, not sandbox assumptions. None runs with a fixture counted as evidence.

| Case | Expected |
| --- | --- |
| Every `/admin` operation as anonymous, user, member, gym owner, approved sponsor | 401 or 404, identical body |
| Every operation at A0, A1, wrong permission, right permission | Per matrix; matrix generated from the router, so a new route without a declared permission fails |
| Operator suspended or revoked between authority check and lock | Refused |
| Two concurrent approvals; approval and withdrawal; approval and revocation | One outcome, no partial state |
| Self-grant, self-review, last-manager revoke | Refused |
| Bootstrap: rerun, wrong environment, expired, altered, unknown user, no identity | Refused, nothing written |
| Applicant DTO and operator DTO | Exact keys; canaries for private fields never appear |
| `/me/entry` for an operator | Same as a non-operator |
| Member of X on all Y paths | 404 |
| Stale revision on every write | 409 |
| Audit update and delete | Refused by database |
| File: wrong type, oversize, pending scan, other applicant | Refused |
| Prod build | Compiles with a disabled or reviewed backend only |

## 4. Monitoring

Using existing telemetry (ADR 0008), reasons only: refused privileged calls, step-up failures,
operator changes, approvals. Alert routing is empty until someone is on call. **A signal nobody watches
is not a control** ([D-SA22](sponsor-admin-decision-register.md)).
