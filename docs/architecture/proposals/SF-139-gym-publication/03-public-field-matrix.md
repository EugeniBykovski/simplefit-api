# 03 — Public field matrix, people and badges

**Status: PROPOSED.** A public DTO lists its fields explicitly and is projected from the
approved snapshot. It never serializes a gym, location or staff struct.

## 1. Field allowlist

"Release 1" is the recommendation. "Later" needs its own decision.

| Field | Source today | Release | Required | Owner edits | Operator moderates | Basis | In search index | Privacy risk |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Public name | `gyms.name` copied into the snapshot | 1 | Yes | Yes | Yes | Owner attestation | Yes | Low; impersonation risk |
| Slug | **New** | 1 | Yes | Once, then by request | Yes | Generated, reserved words refused | Yes | Low |
| Gym type | `gyms.gym_type` | 1 | Yes | Yes | Yes | Business fact | Yes | Low |
| Tagline | `gyms.tagline` | 1 | No | Yes | Yes | Owner text | Yes | Medium; free text can name people |
| City | `gym_locations.city` | 1 | Yes | Yes | Yes | Business fact | Yes | Low |
| Country | `gym_locations.country_code` | 1 | Yes | Yes | Yes | Business fact | Yes | Low |
| Public business address | `gym_locations.address_line`, by opt-in | 1 opt-in | No | Yes | Yes | Explicit opt-in | No, at first | **High for home-run gyms**: may be a private home |
| Public telephone | `gyms.phone`, by opt-in | 1 opt-in | No | Yes | Yes | Explicit opt-in | No | **High**: may be a personal mobile |
| Website | `gyms.website` | 1 opt-in | No | Yes | Yes | Business fact | No | Low; link abuse |
| Accent colour | `gyms.accent_color` | 1 | No | Yes | No | Fixed palette | No | None |
| Verification badge | Derived, never stored in the snapshot | Later | — | No | Derived | §4 | Filter only, later | Implies a claim |
| Logo | **New**, no attachment mechanism exists | Later | No | Yes | Yes, pre-publication | Image rights attestation | No | Medium; rights |
| Cover image | **New** | Later | No | Yes | Yes, pre-publication | Rights and consent of people shown | No | **High**: can show identifiable people, minors |
| Description | **New** | Later | No | Yes | Yes | Owner text | Yes | Medium |
| Contact email | **New**: a dedicated business address, never an account's | Later | No | Yes | Yes | Explicit | No | Medium; scraping |
| Social links | **New** | Later | No | Yes | Yes | Owner | No | Low; link abuse |
| Disciplines | **New**; `gym_type` covers release 1 | Later | No | Yes | Yes | Owner | Yes | Low |
| Training offerings | **New** | Later | No | Yes | Yes | Owner | Yes | Low; consumer claims |
| Amenities | **New** | Later | No | Yes | Yes | Owner | Later | Low |
| Map coordinates | **New**, no geocoding exists | Later, probably never exact | No | Derived | Yes | Separate decision | No | **High** with a home address |
| Public class schedule | Occurrences: `title`, `starts_at`, `venue` | Later | No | Via timetable | **Gap**: titles are free text, unreviewed | Separate opt-in | No | Medium; titles can name people |
| Public coaches | Staff plus §3 opt-in | Later | No | Coach-controlled | Yes | Coach's explicit consent | No | **High** |
| Public booking availability | Capacity minus bookings | Not proposed | — | — | — | — | No | Medium; reveals attendance; needs commerce decisions |

## 2. Never public

Not by default, not by opt-in, not by an owner's request.

| Data | Where it lives |
| --- | --- |
| Owner's or staff's personal email, phone, name | Accounts, identities |
| Member identity, rosters, counts of named people | `gym_members` |
| Staff lists | `gym_staff_memberships` |
| Medical or health data, training logs, RPE, weight, notes | Coaching and training domains (D-G06) |
| Coach–Fighter relationships | Coaching domain (D-G07) |
| Private messages | — |
| Attendance, bookings, attendee counts | `gym_class_bookings`, `gym_class_check_ins` |
| Revenue, plans, invoices, Stripe ids, billing records | Billing |
| Join codes, invitation tokens | Enrollment |
| Verification details, evidence, storage keys, signed URLs, reason codes | Verification |
| Operator notes, identities, audit history, moderation state | Operator domain |
| Entrance notes | `gym_locations.entrance_note`: may hold door codes |
| `gym_id` | Internal; public clients use the slug |
| Publication status other than "published" | A non-published gym is simply not found |

**Aggregates too.** The design's "142 athletes trained today" and "12 of your friends train
here" are excluded: no contract supports them, small counts identify people, and a friend
overlay needs a social graph that doesn't exist.

## 3. Coaches and staff

Staff membership grants no permission to publish a person.

| Question | Proposal |
| --- | --- |
| Can coaches be listed? | Not in release 1. Later, yes, by opt-in |
| Who starts it? | The owner or manager may *request*; only the coach can accept |
| Coach opt-in | Explicit, per gym, per person, recorded with time and policy version. Silence is no |
| CoachProfile required? | No. A coach may lack one. If one exists, it isn't linked or disclosed by the listing |
| Data shown | A display name the coach enters for this listing, and role title. No photo at first. No contact details |
| Affiliation | Must be an active staff membership with role `coach`, checked at read time |
| Revocation | The coach can withdraw at any time, immediately, with no owner approval |
| Stale affiliation | Ending the membership removes the listing in the same transaction |
| Owner removal | The owner can remove a listing but can't add one without acceptance |
| Other roles | Managers and front desk aren't listed |
| Fighters | No FighterProfile is ever disclosed by gym publication. No implied Coach–Fighter relationship |

The instructor field on a class is **not** consent: a public schedule must omit the instructor
unless that person has an active listing.

## 4. Verification badge

Not in release 1. No "Trusted", "Safe" or bare "Verified".

| Question | Proposal |
| --- | --- |
| Wording | "Business details reviewed" |
| What was checked | Under policy `sf103-generic-1`: a legal name, a registration country and at least one document were reviewed. **Per-country rules are empty today, so this is a weak claim** |
| Who | A SimpleFit operator with trusted authority |
| When | Date of the last approval, shown |
| Expiry | Proposed 12 months (D-G11.14). None exists today |
| Removal | Any change to eligibility hides it on the next read, by derivation. Caches: [05](05-routes-api-search-cache.md) |
| Explanation | One plain sentence and a link: "SimpleFit reviewed documents showing this business is registered. It says nothing about the quality or safety of training, coaching or facilities." |
| Evidence | Never shown. Nor legal name, registration number or reason codes |

A badge is derived on every read from the current application. It isn't copied into the
snapshot. A row with `local_fixture` or legacy attribution never produces one.

The copy needs legal review: a badge is a claim made by SimpleFit to consumers.
