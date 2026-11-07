# Sponsor & Admin — decision register (SF-107)

**No decision below is approved.** A status changes only with evidence of who approved it and when.
A design illustration isn't an approval. **Owner** is the role that must decide; "founder" means
whoever holds that authority for the company.

## Already in force

Not reopened unless stated. Evidence is the merged document.

| Id | Decision | Evidence |
| --- | --- | --- |
| ADR 0009 | One global user; no role or type on `users` | ADR 0009, CLAUDE.md rule 13 |
| D-ADMIN-IDENTITY | Admin uses the same global user. No separate admin user | Registry, decided 2026-10-06 |
| D-MOBILE-SPONSOR-ADMIN | No mobile Sponsor or Admin surface | Registry |
| D-G01 | No generic workspaces table | ADR 0026 |
| SF-136 | Session isn't operator proof; no interim authority; no email allowlist; per-call check | ADR 0026 amendment, merged |
| SF-138 | Billing commands refused in production until SF-110; Stripe Live NO-GO | ADR 0026 amendment |
| D-WORKSPACE-NOT-IN-URL | Sponsor workspace in session context | Registry. **D-SA26 proposes to change this** |
| D-ADMIN-SPONSOR-CAMPAIGN-PATHS | No application route unless a domain ticket makes it addressable | Registry. SF-107's proposal is that ticket |

## Sponsor product

| Id | Decision | Recommended | Alternatives | Rationale | Depends on | Owner | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D-SA01 | When is an account required? | Before SP1 | Browser-only draft, account at SP8 (the design) | Resume, no anonymous upload, ADR 0016 fits, less personal data in browsers | Design change | Founder | PROPOSED |
| D-SA02 | Application states | The seven in the [lifecycle](sponsor-application-lifecycle.md) | Add `paused`; drop `under_review` | Minimal, and matches what applicants see | — | Founder | PROPOSED |
| D-SA03 | Reapplication after rejection | New application with new id, no automatic cooldown | Cooldown (30 days or other); ban | Simple. Rate limit covers spam | D-SA02 | Founder | PROPOSED |
| D-SA04 | Sponsor business verification | Not in MVP; a separate later process | Require documents at application | Nothing public or paid depends on it yet. **Revisit before anything public or commercial** | D-SA19 | Founder, counsel | PROPOSED |
| D-SA05 | Budget semantics | One band list, EUR, per year, non-binding, internal, never public, never a decision rule | Remove the step; collect exact amounts | SP5, AS1, AS2 and SPC4 disagree | — | Founder | NEEDS DECISION |
| D-SA06 | CRM stages (AS4) | Not in product for MVP; track outside | Build Lead→Former now | No sponsors yet. Doesn't belong in authority or lifecycle | — | Founder | PROPOSED |
| D-SA07 | Organization ownership | One owner, starting as applicant; transfer needs acceptance | Several owners; operators may transfer | Same as gyms | — | Founder | PROPOSED |
| D-SA08 | Editing organization data | Brand fields by owner or manager. Legal name by re-review | Free edit; operators edit | Stops a bait and switch after approval | D-SA04 | Founder | PROPOSED |
| D-SA09 | Application fields and uploads | SP1–SP7 only. Remove AS2's VAT, size and "partner before", or add them to SP1. **Ship without uploads unless a scanner exists** | Add a scanner now | Don't collect what isn't needed. T23 | Scanner | Founder, counsel | NEEDS DECISION |
| D-SA10 | Approval semantics | Approval creates an active organization and owner membership. **Grants no contract, plan, placement, entitlement or public listing** | Approval only, activation separate; approval includes contract | Keeps layers separate | Lifecycle | Founder | PROPOSED |
| D-SA11 | Supported sponsor types | Businesses in SP1's industries. Restricted list as a **reviewer checklist**: gambling, alcohol, tobacco (from AS1, AdRules) | Automatic rejection; individual sponsors | Policy needs an owner. The design's list is not approved | Counsel | Founder, counsel | NEEDS DECISION |
| D-SA12 | Multi-organization and invitations | Allowed; invitations in MVP after first approval. One current application per user | Single organization per user; invites later | An agency is plausible. Model handles it cheaply | D-SA26 | Founder | PROPOSED |
| D-SA19 | Public versus internal Sponsor data | Nothing public in MVP. Budget, contact, goals, files never public | Public partner list, logos | Same logic as SF-139; a public logo is a claim | Counsel | Founder, counsel | PROPOSED |
| D-SA21 | Marketplace scope | No opportunities, discovery or marketplace | Build with examples | No fake opportunities | Campaign domain | Founder | PROPOSED |
| D-SA22 | Staffing and service levels | Name who reviews and watches alerts. No promised times until then. Remove "5 business days", "Sarah" | Keep promises | A false promise and an unwatched queue | — | Founder | **BLOCKED**: no staff named |
| D-SA23 | Monetization | None in MVP. Sponsor invoicing and flat fees are a later decision | Charge at approval | Stripe Live NO-GO; no B2B invoicing | SF-138 | Founder, finance | PROPOSED |
| D-SA24 | Sponsor analytics | None until measured. If later: aggregate only, suppression threshold (design says 50) | Show examples | No invented reach. Threshold needs privacy review | Tracking, counsel | Founder, counsel | PROPOSED |
| D-SA26 | Sponsor workspace URLs | Id-based, `/sponsor/:sponsorId/*` | Keep session context | Same reasons as D-G23; session context was never built | Registry update | Founder | PROPOSED; **reopens a resolved registry decision** |

## Platform operators

| Id | Decision | Recommended | Alternatives | Rationale | Depends on | Owner | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D-SA13 | Operator bootstrap | [The ceremony](platform-operator-trust.md#5-founder-bootstrap) | Rejected list there | Independent authorization, identity binding, evidence | D-SA15 | Founder, security reviewer | PROPOSED |
| D-SA14 | Second operator | Name one before activation | Solo at first, with gyms and orgs of the founder unreviewable | F8; no recovery or review otherwise | D-SA22 | Founder | **BLOCKED**: no one named |
| D-SA15 | Operator authentication | WebAuthn hardware keys first, no IdP or VPN | Okta plus key, as AD0; TOTP | Smallest real assurance; TOTP is phishable | Dependency review | Founder, security reviewer | PROPOSED |
| D-SA16 | Permission names and tiers | [The matrix](sponsor-admin-permissions.md) | Coarse roles; AD0b's session scopes | Per-action, explicit, least privilege | — | Founder | PROPOSED |
| D-SA17 | Two-person rule | MVP excludes operations that need it (ban, deletion, export, money). Add with a second operator | Self-approval; single-person with notice | AD20's approvers don't exist | D-SA14 | Founder | PROPOSED |
| D-SA18 | Audit retention | Keep everything until counsel decides; no automatic deletion | 7 years (AD14); forever (AD10) | Figures aren't approved. Personal data in audit is minimal | Counsel | Counsel | NEEDS DECISION |
| D-SA20 | Admin access to sensitive records | Exact search, masked email, no private data endpoint, reason on read | AD7 browse-all | Least privilege | D-SA16 | Founder, counsel | PROPOSED |
| D-SA25 | Admin first-run | Presentation only, never a gate. Truthful checklist: key enrolled, permissions, where audit is. Runbooks and shadowing only if they exist | ARW1 as drawn; blocking checklist | Authority can't depend on onboarding | — | Founder | PROPOSED |
| D-SA27 | Sponsor users on mobile | Handoff row only | Mobile portal | Extends D-MOBILE-SPONSOR-ADMIN | — | Founder | PROPOSED |
| D-SA28 | Production access controls | Separate database roles, restricted shell, documented access | Accept the risk, in writing | App controls can't stop a superuser; SF-136 said so | Infrastructure | Founder | NEEDS DECISION |
| D-SA29 | User restriction | Reversible suspension only in MVP, with a new table. Bans and deletion later | No restriction at MVP | `web.account.suspended` needs a real source; appeal rights need counsel | Counsel | Founder, counsel | NEEDS DECISION |

## Legal and design

| Id | Decision | Recommended | Alternatives | Rationale | Depends on | Owner | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D-SA30 | Canvas capacity and approval | Decide where new boards go, and mark Sponsor and Admin boards FUTURE or MVP | New canvas; leave as is | SF-139 recorded a file limit. No Sponsor or Admin board is marked, unlike sections 18, 26 and 4 | — | Founder | NEEDS DECISION |

### Questions for counsel

Not decided here, and nothing here is legal advice:

Who is the legal entity? What must the applicant declare? Privacy notice for business contacts; GDPR
roles; DPO need (the design names one); operator access and employee monitoring; retention; DSAR process;
data agreement; restricted categories by market; business age (registration allows 16+, whether an
applicant must be an adult); suspension notice and appeal, including under the EU Digital Services Act;
advertising labelling, if placements ever ship.

## First decisions

Each unblocks the next.

| # | Decision | Unblocks |
| --- | --- | --- |
| 1 | Approve or change this architecture, including ADR 0027 | Everything |
| 2 | D-SA13, D-SA15: bootstrap and authentication | SF-110 |
| 3 | D-SA14, D-SA22: who operates and reviews | Activation, not the build |
| 4 | D-SA01, D-SA02, D-SA10: application path and meaning | Sponsor backend and design |
| 5 | D-SA26: URLs | Registry work |
| 6 | D-SA05, D-SA09: fields | Application form |
| 7 | D-SA30, then design tasks | UI work |
| 8 | Counsel on the questions above | Opening applications |
