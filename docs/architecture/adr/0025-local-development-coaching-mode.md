# ADR 0025 — LOCAL DEVELOPMENT coaching mode

* Status: Accepted (SF-81, 2026-10-23). Epic SF-48.
* Context: ADR 0021 (Coach–Fighter relationships, invitations), ADR 0022
  (legal documents, coaching policy), SF-56/57/58/60/71/72.

## Problem

Coach–Fighter sharing is fail-closed (ADR 0021, 0022). Without published
legal documents, a configured disclosure and data rules, and the gate flag,
nothing in the workflow is available. Developers testing the workflow on
their own machine had to configure test-only legal fixtures for every run,
or keep a separate sandbox API.

## Decision

One explicit regime decision, `SimpleFit.Coaching.LegalPolicy.mode/0`, with
three values. Every legal decision of the coaching context asks it; nothing
else reads the mode or the environment.

| Mode                        | When                                                                              | Legal documents                                             |
| --------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `:production_approved`      | gate on, valid registry, published disclosure and data rules (unchanged, ADR 0022) | shown, acknowledged/accepted per language, evidence recorded |
| `:local_development_bypass` | `SimpleFit.Coaching.LocalDevelopment.active?/0`                                   | none                                                        |
| `:blocked`                  | otherwise                                                                         | coaching unavailable                                        |

### Activation (`SimpleFit.Coaching.LocalDevelopment`)

Decided once at boot, by a supervision child after the repo and before the
endpoint. Every condition is required:

1. **Build**: `config/dev.exs` sets `allowed: true`. No production or
   release configuration sets it. `active?/0` is compiled against it, so a
   production build answers `false` whatever its runtime state.
2. **Build environment** `:dev` (compile time), and not an OTP release.
3. **Opt-in**: `SIMPLEFIT_LOCAL_DEV_COACHING=enabled`, read by
   `config/runtime.exs` in the `:dev` branch only.
4. **Loopback endpoint**: `PHX_BIND_ALL` is not set.
5. **Local database**: the repo's configured host is loopback, and the live
   connection's server address is loopback or a Unix socket. A tunnel or
   proxy to a remote server fails here.
6. **Approved database**: the live `current_database()` is in
   `config/dev.exs` `databases` (`simple_fit_dev`).

A refused opt-in is logged with the failed checks; an active mode is logged
as a warning at boot. `config/test.exs` also allows the mode, but only so
tests can run the domain under it through `put_active_for_test/1`, a
function compiled into the test build alone. The real activation refuses the
test build.

### What the mode changes

* Coaches invite without coach data rules. There are none to show or
  acknowledge, and `acknowledgeMyCoachDataRules` answers `404`.
* The invitation preview has no legal text (`document: null`). Its
  `disclosure.version` is the marker `local-development-no-legal-text`, and
  its fields are the `basic_profile` scope.
* The fighter still accepts **explicitly**: an acceptance request echoing the
  disclosure version the preview showed. `document_language` is not needed,
  because no text was shown.
* The relationship and the consumed invitation record the marker in
  `disclosure_version` / `accepted_disclosure_version`. The marker is not a
  legal version; it states that no legal text was accepted. **No legal
  evidence is recorded**, and no acknowledgement row is written.
* The marker discloses its scope **only while the mode is active**. In any
  other mode it discloses nothing and is never offered, so a database used in
  local development fails closed as soon as the mode is off.
* Clients learn the regime from one field, `legal_mode`
  (`approved` | `local_development`), in the data-rules and preview
  responses. In `local_development` they show no legal acknowledgement and
  say that this is development mode.

### What the mode never changes

Authentication and sessions, recipient binding to a verified email identity
(SF-57/SF-73), explicit acceptance, completed account and profiles, 18+ (SF-71),
self-coaching, IDOR protection, invitation expiry, replay, locking,
concurrency and abuse limits, and training authorization. The legal
registry, `priv/legal` and the approved configuration are untouched.

## Consequences

* `localhost:3000` → `localhost:4000` → `simple_fit_dev` supports the whole
  workflow after `export SIMPLEFIT_LOCAL_DEV_COACHING=enabled` and an API
  restart. No migration.
* Relationships created in local development carry the marker and show no
  fighter fields once the mode is off. That is intended.
* A database other than `simple_fit_dev` (e.g. an E2E database) never gets
  the mode; those runs keep using the test-only legal fixtures.
