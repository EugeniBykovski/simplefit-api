# Sponsor & Admin — identity and context boundaries (SF-107)

**Status: PROPOSED.** Builds on ADR 0009 (one global user), 0016 (registration), 0017 (entry),
0026 (gyms) and the SF-136 amendment.

## 1. The model

**One global User. Independent profiles, memberships and capabilities.**

```
User (id only; ADR 0009)
├── Identity (email, Google, Apple)              signs in; proves nothing else
├── Session                                      proves a user, not an operator (SF-136)
├── AccountProfile, AccountConsent               shared registration (ADR 0016)
├── FighterProfile → FIGHTER
├── CoachProfile → COACH
├── GymStaffMembership → GYM_WORKSPACE
├── GymMember                                    participant; grants no capability
├── SponsorApplication                           a request; grants nothing          (proposed)
├── SponsorWorkspaceMembership → SPONSOR_WORKSPACE                                  (proposed)
└── PlatformOperator → ADMIN                     separately trusted; never self-made (proposed)
```

**Never added:** `User.role`, `User.type`, a Sponsor or Admin user table, a separate Sponsor
authentication database, or permissions from registration intent. `users` gains no column.

## 2. No context grants another

Read a row as: holding this gives that. Every cell is **No** except where stated.

| Holding ↓ gives → | Fighter data | Coach rights | Gym rights | Sponsor rights | Operator authority |
| --- | --- | --- | --- | --- | --- |
| Identity or session | No | No | No | No | **No** (SF-136) |
| Entry intent or role choice | No | No | No | No | **No** |
| Account registration | No | No | No | No | **No** |
| Fighter or Coach profile | Own only | Own only | No | No | **No** |
| Gym owner or staff | No | No | That gym only | No | **No** |
| Sponsor application, in any state | No | No | No | **No** | **No** |
| Sponsor membership | No | No | No | That organization only | **No** |
| Approved business verification | No | No | Go-live input only | No | **No** |
| Operator, any permission | **No**, except as [§4 of permissions](sponsor-admin-permissions.md#4-sensitive-data-access) | **No** | Only the action granted | Only the action granted | Only as granted |

Three rules follow:

1. **Sponsor approval never grants operator authority.**
2. **Operator authority never comes from creating an account, picking anything in onboarding or
   submitting an application.** It comes only from the process in
   [operator trust](platform-operator-trust.md).
3. **An operator isn't a member of what they review.** Operators don't appear in an
   organization's or gym's member list, and being an operator doesn't open sponsor or gym routes.

A person may hold all of these at once. Each request is authorized only by the context it names.

### Worked example

One person is a fighter, owns a gym, belongs to a sponsor organization and is an operator with
`sponsors.applications.decide`.

| They try to | Result | Why |
| --- | --- | --- |
| Approve their own organization's new application | Refused | Conflict: applicant or member, checked by user id |
| Approve their own gym's verification | Refused | SF-136 conflict rule |
| Read another fighter's training | Refused | No permission exists |
| Use their gym's rights in the operator console | Not applicable | Separate paths and checks |
| See invoices in their sponsor org as a `member` | Refused | Sponsor role decides, not operator status |

## 3. Domain boundaries

### Contexts

| Context | Owns | Calls |
| --- | --- | --- |
| `SimpleFit.Sponsors` (new) | Applications, organizations, memberships, invitations | `Accounts`, `Storage`, `Email`, `Operators` through its authority function |
| `SimpleFit.Operators` (new) | Operators, credentials, step-ups, assignments, audit | `Accounts` |
| `SimpleFit.Gyms` | As today | `Operators` through a real `VerificationAuthority` backend after SF-110 |

Neither writes another's tables. `Operators` knows nothing about sponsors or gyms: a reviewing
domain asks "may this credential do this permission now?" and enforces its own rules, including
conflicts of interest. **A shared review screen must not become a shared authorization check.**

### Why no shared `workspaces` table

ADR 0026 D-G01 rejected a generic workspace table for gyms. Sponsors follow the same pattern with
their own tables. The route registry's "WorkspaceMembership (Sponsor)" is a concept, not a table.

### SponsorOrganization

The accepted business.

| Question | Proposal |
| --- | --- |
| Created when | Only in the approval transaction. Never by the applicant, and never before approval |
| Fields | Legal name, brand name, website, country, industry, description, logo. Copied from the approved revision, then owned by the organization |
| Who edits | Owner or manager, for brand fields. A legal name change needs review ([D-SA08](sponsor-admin-decision-register.md)) |
| Lifecycle | `active`, `suspended`, `closed`. No draft: drafts are applications |
| Verification | **Not a column.** MVP has no sponsor business verification. The future process gets its own table so approval can't set it by accident ([D-SA04](sponsor-admin-decision-register.md)) |
| Public visibility | **None in MVP.** No public profile, logo or list until a policy is approved, as for gyms in SF-139 |
| Duplicate names | Allowed. Names aren't unique, and a name proves nothing. The reviewer judges |

### SponsorWorkspaceMembership

| Question | Proposal |
| --- | --- |
| Roles | `owner`, `manager`, `member`. A fixed matrix in code, as `Gyms.Policy` |
| Read-only role | **Not justified yet.** `member` reads and has no invoice or team access. Add on need |
| Owners | Exactly one active owner, database enforced, as gyms |
| Multiple organizations | Allowed by the model; one user may belong to several. Agencies are the likely case |
| Ownership transfer | Atomic transfer to an active member, who accepts. No operator shortcut in MVP ([D-SA07](sponsor-admin-decision-register.md)) |
| Revocation | Ends at once. Next request is 404 for that organization |
| Owner leaves | Must transfer first. Account deletion by an owner: blocked or transferred, the same open question as gyms |

### SponsorInvitation

Same shape as gym staff invitations (SF-93, SF-133): one-time token stored as a hash, bound to a
verified email identity (ADR 0021, 0024), with cancel, decline, expiry and resend. An invitation
can't grant `owner`.

### SponsorApplication

| Distinct from | Why |
| --- | --- |
| An approved organization | Created only on approval |
| A workspace membership | Created only on approval, and only for the applicant |
| A partnership contract | No contract is created or implied |
| A paid subscription | No plan, entitlement or Stripe object is touched |
| A sponsorship agreement | Budget and interests are non-binding statements |

Who can save what is in the [lifecycle](sponsor-application-lifecycle.md#2-what-can-be-saved-and-when).

## 4. What SF-136 fixes in place

| Rule from SF-136 and SF-138 | Effect here |
| --- | --- |
| A session proves a user, not an operator | Operator checks read `platform_operators` and require a key check on the session |
| No email allowlist, shell argument or flag | None is proposed, including for bootstrap |
| Authority asked on every call, no cache, again after locks | The same contract for Sponsor decisions |
| Immutable actor id plus user id | `OperatorPrincipal` shape kept |
| No interim authority | Sponsor review doesn't ship before SF-110 |
| Fixture attribution is never trust | `local_fixture` remains non-trusted; a new reviewed value is added |

## 5. Approval and verification boundaries

Seven separate processes. Passing one satisfies no other.

| Process | Question it answers | Decided by | Result | Permission | MVP |
| --- | --- | --- | --- | --- | --- |
| Sponsor application review | Do we want to work with this business? | Operator | Application `approved` or `rejected` | `sponsors.applications.decide` | Yes |
| Sponsor organization activation | Does the workspace exist and work? | Automatic in the approval transaction | Organization `active`, owner membership | Same transaction | Yes |
| Sponsor organization verification | Is it the legal business it claims? | Operator, with evidence | Future verification row | Future | **No** |
| Sponsor commercial contract | What did we agree? | Founder, counsel | Future agreement row | Future | **No** |
| Platform operator authorization | May this person act for SimpleFit? | Ceremony, or `operators.manage` | Operator and assignments | `operators.manage` | Yes |
| Gym business verification | Is this gym the claimed business? | Operator (SF-103) | Verification `approved` | `gyms.verification.*` | Yes, after SF-110 |
| Gym public publication | May this gym be public? | Operator (SF-139) | Publication `published` | `gyms.publication.*` | When approved |

### What may be shared

| May share | Must stay separate |
| --- | --- |
| Authentication and step-up | Each permission |
| Queue table and detail UI components | Each transition function |
| Audit table | Each domain's state and history |
| Conflict-of-interest helper for "is this user a party" | Each domain's definition of a party |
| File scanning and storage | Each domain's file purposes and access checks |

A Sponsor application reviewer gets no gym verification or operator-management permission.

## 6. Entry resolution

Amends ADR 0017. Today `sponsor` always leads to `sponsor_application`. Proposed rule 3, sponsor
part, reading real state and writing nothing:

| Sponsor state of the user | Destination |
| --- | --- |
| No application, no membership | `sponsor_application` → `web.partners.apply` |
| Draft | `sponsor_application_draft` → `web.app.onboarding.sponsor` |
| Current application in any other non-terminal state | `sponsor_application_status` → `web.sponsor.application` |
| Latest application rejected or withdrawn, no membership | `sponsor_application_status` → `web.sponsor.application` |
| One active membership | `sponsor_home` → `web.sponsor._sponsor-id.dashboard`, with `sponsor_id` |
| Several | Remembered one if valid, otherwise `context_selection` |

Rule 1 is unchanged: account registration comes first.

* **Capabilities:** `SPONSOR_WORKSPACE` projects from an active membership in an active
  organization. As with `GYM_WORKSPACE`, that's for routing; every operation authorizes its id.
* **`ADMIN` is never projected by `/api/v1/me/entry`**, and entry never routes to `/admin`. Entry is
  a general endpoint, and revealing who is an operator there serves nobody. Operator state comes
  only from `GET /api/v1/admin/me`.
* **Mobile:** every sponsor destination maps to the web handoff. No sponsor screens in mobile.
* **Context choice:** `sponsor` joins `gym` as a remembered landing preference with an id, and it's
  never authority (D-G23).

## 7. Account and context switching

| Situation | Rule |
| --- | --- |
| Switching contexts | Navigation. Grants nothing, and each page authorizes its own id |
| Signing out or switching account | Clears client caches (SF-28), and step-up ends with the session |
| Session expires mid-review | The write is refused. Nothing is half-applied |
| Membership or grant revoked with the page open | The next request fails, whatever the page shows |
| Applicant's account deleted | Open application becomes `withdrawn`. Applicant id is nullified; submitted history stays |
| Operator's account deleted | Blocked while the operator record is active. Revoke first. History keeps the operator id |
