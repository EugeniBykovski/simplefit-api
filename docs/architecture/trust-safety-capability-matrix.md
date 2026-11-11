# Trust & safety capability matrix (SF-125)

Evidence-based inventory of what could be moderated, taken from the schema (`priv/repo/migrations`), the router
and the contexts at `17c1319`. Decision: [D-SA32](sponsor-admin-decision-register.md).

| Domain | Exists? | Public / private | Reporting | Hide / unhide | Appeal | Operator action today |
| --- | --- | --- | --- | --- | --- | --- |
| Posts, comments, feeds, private messages, media | **No**: no table, route or context | — | — | — | — | — |
| Reports / flags | **No**: no table or endpoint (AD4 "No reports domain") | — | — | — | — | — |
| Enforcement cases, strikes | **No** (AD11 "No enforcement domain") | — | — | — | — | — |
| Appeals | **No**: only user-side design boards (WS4, ST15); notice and appeal need counsel (D-SA29) | — | — | — | — | — |
| Fighter profile (`fighter_profiles`) | Yes | Private: own view; an accepted coach sees an allowlist (`Fighters.coach_visible_fields/0`); nothing public | No | No visibility state | No | Read: `fighters.read` (SF-123) |
| Coach profile (`coach_profiles`) | Yes | Private: display name and brand to that coach's fighters; nothing public | No | No | No | Read: `coaches.read` (SF-123) |
| Gym (`gyms`) | Yes | Staff and members; name in invitation previews; no public page (publication: SF-139 proposal) | No | No publication or suspension state (SF-107 task A9) | No | Read: `gyms.read` (SF-123) |
| Sponsor organization | Yes | Its members only | No | Suspend / reinstate is business review (SF-116), not moderation | No | `sponsors.restrict` |
| Account | Yes | — | No | — | No | Suspend / lift / sign out everywhere: `users.restrict`, `users.sessions.revoke` (SF-122) |

The only unauthenticated reads are legal documents (SF-72) and invitation/join previews; none carries
user-generated content.

## Before a reports domain can be built

1. What can be reported, by whom (a participant who can see it), and how floods and duplicates are handled.
2. Report reasons, what evidence is kept and for how long (retention, D-SA18).
3. What "hidden" means for each content type and the read boundary that enforces it.
4. Notice to the person and appeal (counsel; D-SA29), and whether reporters are told anything.
5. `moderation.read` and `moderation.action` in the catalog by a reviewed migration (SF-107 lists them FUTURE),
   kept separate from account restriction (SF-122) and gym verification review.
