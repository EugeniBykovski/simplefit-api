# SF-71 — Legal analysis and Privacy Notice / Terms impact

**STATUS: DRAFT — REQUIRES PRODUCT AND LEGAL APPROVAL**

Ticket SF-71 (brief §2, §9, §12). This is research for counsel, not legal
advice and not a compliance statement. All sources were checked on
**2026-10-19**. "Law" = established legislation; "Guidance" = regulator
guidance; "Recommendation" = this proposal.

## 1. Sources

| # | Jurisdiction | Source | Status | Official URL | Checked |
|---|---|---|---|---|---|
| S1 | EU | Regulation (EU) 2016/679 (GDPR), OJ L 119, 4.5.2016 (text read from the Publications Office PDF; EUR-Lex returned a bot challenge) | Law | https://eur-lex.europa.eu/eli/reg/2016/679/oj | 2026-10-19 |
| S2 | EU | EDPB Guidelines 07/2020 on the concepts of controller and processor, v2.1 (7 July 2021) | Guidance | https://www.edpb.europa.eu/system/files/documents/2023-10/EDPB_guidelines_202007_controllerprocessor_final_en.pdf | 2026-10-19 |
| S3 | EU | EDPB Guidelines 05/2020 on consent | Guidance | https://www.edpb.europa.eu/documents/guideline/guidelines-052020-on-consent-under-regulation-2016679_en | 2026-10-19 |
| S4 | EU | EDPB Guidelines 2/2019 on Art. 6(1)(b) | Guidance | https://www.edpb.europa.eu/sites/default/files/files/file1/edpb_guidelines-art_6-1-b-adopted_after_public_consultation_en.pdf | 2026-10-19 |
| S5 | EU | EDPB Guidelines 1/2024 on Art. 6(1)(f), v1.0 adopted for public consultation (8 Oct 2024); no final version located | Guidance (draft) | https://www.edpb.europa.eu/our-work-tools/documents/public-consultations/2024/guidelines-12024-processing-personal-data-based_en | 2026-10-19 |
| S6 | EU | EDPB Guidelines 8/2020 on targeting of social media users (non-users' rights, Art. 14) | Guidance | https://www.edpb.europa.eu/system/files/2021-04/edpb_guidelines_082020_on_the_targeting_of_social_media_users_en.pdf | 2026-10-19 |
| S7 | EU | EDPB-EDPS Joint Opinion 2/2026 on the Digital Omnibus proposal COM(2025) 836 (adopted 10 Feb 2026): proposed GDPR changes incl. Art. 4(1), Art. 13, access requests, breaches; **legislative status to be checked by counsel** | Pending legislation | https://www.edpb.europa.eu/system/files/documents/2026-02/edpb_edps_jointopinion_202602_digitalomnibus_en.pdf | 2026-10-19 |
| S8 | PL | Ustawa z dnia 10 maja 2018 r. o ochronie danych osobowych (Dz.U. 2018 poz. 1000; consolidated DU/2019/1781), in force; contains **no** provision lowering the GDPR Art. 8 age (text searched) | Law | https://api.sejm.gov.pl/eli/acts/DU/2018/1000 | 2026-10-19 |
| S9 | PL | Kodeks cywilny, consolidated text Dz.U. 2026 poz. 795, art. 118 (limitation: 6 years; 3 years for periodic and business-related claims; end of calendar year) | Law | https://api.sejm.gov.pl/eli/acts/DU/2026/795 | 2026-10-19 |
| S10 | PL | Prawo komunikacji elektronicznej (Dz.U. 2024 poz. 1221), art. 398: commercial information to an end user by electronic means requires prior consent | Law | https://api.sejm.gov.pl/eli/acts/DU/2024/1221 | 2026-10-19 |
| S11 | UK | UK GDPR Art. 8: age 13 for information society services (DPA 2018 s. 9 omitted since 31.12.2020) | Law | https://www.legislation.gov.uk/eur/2016/679/article/8 | 2026-10-19 |
| S12 | UK | ICO Age appropriate design code (Children's code), 15 standards | Statutory code / Guidance | https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/childrens-information/childrens-code-guidance-and-resources/age-appropriate-design-a-code-of-practice-for-online-services/ | 2026-10-19 |
| S13 | UK | Data (Use and Access) Act 2025 (amends UK GDPR/PECR; impact not analysed) | Law | https://www.legislation.gov.uk/ukpga/2025/18/contents | 2026-10-19 |
| S14 | US | COPPA Rule, 16 CFR Part 312; amendments published 22 Apr 2025, effective 23 Jun 2025, compliance by 22 Apr 2026 | Law (federal regulation) | https://www.ftc.gov/legal-library/browse/federal-register-notices/16-cfr-part-312-coppa-final-rule-amendments | 2026-10-19 |

Not researched (flagged for counsel): Directive 2002/58/EC national
transpositions beyond Poland; EU consumer law (Directive 2011/83/EU, Unfair
Terms Directive) for coach terms; Digital Services Act obligations of
SimpleFit as a hosting/online platform; US state privacy laws (e.g. California
CCPA/CPRA) and state children's design codes; CJEU joint-controllership case
law (C-210/16 *Wirtschaftsakademie*, C-25/17 *Jehovan todistajat*, C-40/17
*Fashion ID*), named for counsel without analysis here.

## 2. Analysis and questions for counsel

### 2.1 Roles (L-01)

* **SimpleFit** determines why and how fighter data is shown to coaches
  (fields, gate, versions, retention): **controller** for the platform
  processing (GDPR Art. 4(7); S2). Recommendation, high confidence.
* **Coach** decides to invite and uses what they see for their own coaching
  business; coaching is a professional activity, so the household exemption
  (Art. 2(2)(c), "no connection to a professional or commercial activity")
  does not apply. For use **outside the platform** (notes, own records) the
  coach is plausibly a **separate controller**. Whether coach and SimpleFit
  are **joint controllers** (Art. 26) for the invitation and roster display is
  open: the coach co-determines the purpose of a specific disclosure.
  → **Q-01 (counsel, mandatory).**
* **Email and hosting providers**: processors (Art. 28): DPAs and
  sub-processor list required (→ privacy notice).

### 2.2 Legal basis (L-02)

| Option | Fit | Risk |
|---|---|---|
| Consent, Art. 6(1)(a) | The product already collects an explicit, specific, informed, unticked, version-specific, freely given choice per coach, revocable by ending (Art. 7(3) satisfied) | Consent must be freely given and as easy to withdraw; evidence obligations (Art. 7(1)); children rule Art. 8 applies to ISS offered to a child |
| Contract, Art. 6(1)(b) | Connecting with a chosen coach could be the core of the service the fighter requests | EDPB reads "necessary" narrowly (S4); the stub after the end is not necessary for the contract |
| Legitimate interests, Art. 6(1)(f) | Good fit for the stub, invitations to non-users, abuse limits | Balancing test (S5); objection right (Art. 21) |

**Recommendation:** consent (Art. 6(1)(a)) for showing C1/C2 to a coach, as
the in-product acceptance already meets the consent conditions; legitimate
interests (Art. 6(1)(f)) for the ended stub, invitation handling and abuse
limits; legal obligation / legitimate interests for evidence retention.
→ **Q-02 (counsel, mandatory).** Note: the in-product acceptance can be
*both* the product decision and GDPR consent only if counsel confirms consent
is the basis; otherwise the checkbox wording changes (disclosure Part 3).

### 2.3 Special categories (Art. 9)

C1/C2 (name, place, level, stance, bout count) are not special-category data
on their face. Body weight and height (C4, never shared) can be "data
concerning health" in some contexts; boxing experience and bout counts could
indirectly suggest health or fitness. Since none of the C4 data is shared,
the current scope likely stays outside Art. 9. → **Q-03 (counsel).** Any
future sharing of weight, injuries or medical clearance needs a separate
Art. 9 analysis and DPIA (Art. 35).

### 2.4 Minors and age (L-14)

* Product: registration requires age **16** (ADR 0016), no guardian flow, no
  youth coaching.
* EU default age for consent-based ISS processing is 16, Member States may
  lower to 13 (Art. 8(1)); **Poland has not lowered it** (S8), so 16 matches
  Poland. Other Member States set lower ages (counsel to confirm per market);
  a minimum of 16 is stricter, not weaker, for consent purposes.
* UK: 13 (S11) plus the Children's code (S12) for services *likely to be
  accessed by children* under 18: 16–17-year-olds are children under the
  code; high-privacy defaults and best-interests assessment apply.
* US: COPPA applies to under-13s (S14); the 16+ rule keeps the product out of
  COPPA's direct scope if age gating is effective; state laws may treat
  13–17 as minors.
* **16–17-year-old fighters can be coached by adult strangers** through this
  feature. Safeguarding (contact-sport coaching of minors, possible
  national safeguarding rules for sports instructors) is not covered by data
  protection law alone. → **Q-04 (counsel + safeguarding policy owner).**
  Options in the decision register (L-14).
* Contractual capacity of 16–17-year-olds differs by country (Poland: limited
  legal capacity from 13, Civil Code art. 15; contracts commonly concluded in
  minor everyday matters without the legal representative, art. 20; S9).
  Whether accepting the Terms or a paid coaching arrangement falls under
  art. 20 is for counsel. → **Q-05.**

### 2.5 Invitations to non-users (F-06)

The coach supplies an email address of a person who may not be a user.
SimpleFit then processes it (digest, encrypted copy, E08). Art. 14 requires
informing that person at the latest at the first communication
(Art. 14(3)(b)): E08 must carry or link the required information (source:
"a coach on SimpleFit gave us your address", purposes, retention, rights).
Whether E08 is "commercial information" requiring prior consent under Polish
electronic-communications law (S10, art. 398) depends on whether it promotes
SimpleFit's or the coach's services: E08 currently promotes no service and
promises no feature, which supports treating it as a personal,
recipient-specific notification sent at a user's request. → **Q-06 (counsel,
mandatory before activation in Poland).**

### 2.6 Retention and claims

See the [retention policy](SF-71-retention-policy.md). Storage limitation
(Art. 5(1)(e)) applies; keeping evidence for legal claims is an exception to
erasure (Art. 17(3)(e)) only while claims can arise; Polish limitation
periods (S9) are an anchor, not an obligation. → **Q-07, Q-08, Q-09.**

### 2.7 Transparency when a coach receives data

The fighter receives the information before acceptance (disclosure, Art. 13
at collection). The coach receives data from SimpleFit; if the coach is a
separate controller for off-platform use, the coach has own transparency
duties towards the fighter (Art. 14) unless the fighter already has the
information. The disclosure tells the fighter who the coach is and what is
shared, which may satisfy that in substance. → **Q-01.**

## 3. Privacy / Terms change-impact matrix

| Existing document | Required change | Reason | Legal approval | Engineering dependency |
|---|---|---|---|---|
| Privacy Notice (`privacy-v1` identifier; **no published text found**) | Publish a notice at all; add: operator identity and contact [missing], coach–fighter sharing (recipients: coaches the user accepts), invitation processing of non-users, legal bases, retention per policy, rights, processors (email provider, hosting), international transfers [unknown], supervisory authority | GDPR Arts. 12–14 | Mandatory | Public legal pages (L-12); version registry (L-10); re-acknowledgement on change (ADR 0016 hook) |
| Terms of Service (`terms-v1`; **no published text found**) | Publish; add coach-user obligations reference (Data Rules), prohibited uses, suspension, coaches are independent (no verification) | Contract; consumer transparency | Mandatory | Same |
| Coach-specific terms | **New**: Coach Data Access & Usage Rules (this package) | Purpose limitation, confidentiality | Mandatory | Data Rules version + web acknowledgement (F-07) |
| Fighter data-sharing disclosure | **New** (this package) | Arts. 7, 12, 13 | Mandatory | Disclosure version + link in preview (SF-72) |
| Account deletion information | **New**: what deletion removes, what is kept and how long, backups | Art. 17, Art. 13(2)(a) | Mandatory | Account-deletion task (F-05) |
| E08 invitation email | Add invitation privacy statement link; operator identity; one-click "this isn't me" / unsubscribe from further invitations (recommendation) | Art. 14; PL art. 398 analysis | Mandatory | E08 template (SF-72) |
| Data-controller identity | Supply legal entity, address, registration, privacy contact, DPO if required | Arts. 13(1)(a)-(b), 14(1)(a)-(b) | Mandatory | All texts |
| International transfers | Identify providers and locations (email provider, hosting, error tracking, analytics) and transfer tools | Arts. 44–49 | Mandatory | Ops inventory |
| Processor / sub-processor list | Create | Art. 28, transparency | Mandatory | Ops inventory |
| Records of processing (internal) | Add coach–fighter activities | Art. 30 | Recommended | — |
| DPIA (internal) | Screening for coach access to 16–17-year-olds' data | Art. 35 | Counsel to decide | — |

Missing operator facts are flagged, not invented.
