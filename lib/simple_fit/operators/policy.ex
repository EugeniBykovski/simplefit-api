defmodule SimpleFit.Operators.Policy do
  @moduledoc """
  The operator security policy (SF-110, ADR 0028), in one place.

  * **Permissions** - the catalog the database also enforces. SF-110 needs only
    operator management and audit; each later admin ticket adds its own
    permissions in a reviewed migration (SF-107 lists the candidates).
  * **Assurance** - `:key` needs a current security-key check bound to the
    session; `:fresh_key` needs one in the last `fresh_window/0` seconds.
  * **Authenticators** - an operator becomes active only with
    `required_authenticators/0` registered keys (SF-107 proposed two). A
    production build refuses fewer than two.
  """

  # SF-114 adds the first sponsor review permissions, one per action (D-SA16 naming,
  # proposed): reading a submitted application, claiming it, requesting changes.
  # SF-116 adds approving and rejecting (one each, as gym verification has, rather than
  # the matrix's combined `.decide`), downloading submitted files, and suspending or
  # reinstating an approved application's organization (`sponsors.restrict`).
  # SF-121 adds the overview (AD1) and its health card: `platform.dashboard.read` (counts only,
  # no names) and `system.health.read` (check results and job counts, no payloads), both
  # routine reads at a current key check and not audited per load (SF-107).
  # SF-122 adds user administration (SF-107 naming, proposed): `users.read` (exact search,
  # one account, masked, each read recorded with its reason), `users.reveal_email`,
  # `users.restrict` (suspend or lift, D-SA29 MVP) and `users.sessions.revoke` (sign
  # out everywhere), the last three at a fresh key check.
  # SF-123 adds read-only oversight, one permission per domain so none implies another:
  # `gyms.read` (SF-107: list and one gym, counts of people, no member list),
  # `coaches.read` and `fighters.read` (exact lookup, the profile's shared fields and
  # relationship counts, never training, health or messages), all at a current key check.
  # SF-126 adds `system.jobs.read` (the background job list and one job's metadata, never
  # arguments or error messages), separate from `system.health.read`; no job action.
  # SF-127 adds `billing.read` (the billing overview, plan catalog, gym subscriptions and
  # Stripe invoice outcomes) and `billing.reconciliation.read` (discrepancies and webhook
  # inbox metadata), read only at a current key check; no financial write exists.
  # SF-128 adds `config.read` (the configuration inventory and history, key check) and
  # `config.flags.write` (suspend or restore an allowlisted feature, fresh key check).
  # SF-130 adds partnership proposal review, one permission per action as SF-116 did:
  # `sponsors.proposals.read` (queue and detail, key check), `.claim`, `.request_changes`,
  # `.accept` and `.decline` (fresh key check). None of them creates anything commercial.
  @permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                  sponsors.applications.claim sponsors.applications.request_changes
                  sponsors.applications.approve sponsors.applications.reject
                  sponsors.applications.read_files sponsors.restrict
                  platform.dashboard.read system.health.read
                  users.read users.reveal_email users.restrict users.sessions.revoke
                  gyms.read coaches.read fighters.read system.jobs.read
                  billing.read billing.reconciliation.read config.read config.flags.write
                  sponsors.proposals.read sponsors.proposals.claim
                  sponsors.proposals.request_changes sponsors.proposals.accept
                  sponsors.proposals.decline)
  @assurance %{
    "operators.read" => :key,
    "audit.read" => :key,
    "operators.manage" => :fresh_key,
    "sponsors.applications.read" => :key,
    "sponsors.applications.claim" => :fresh_key,
    "sponsors.applications.request_changes" => :fresh_key,
    "sponsors.applications.approve" => :fresh_key,
    "sponsors.applications.reject" => :fresh_key,
    "sponsors.applications.read_files" => :fresh_key,
    "sponsors.restrict" => :fresh_key,
    "platform.dashboard.read" => :key,
    "system.health.read" => :key,
    "users.read" => :key,
    "users.reveal_email" => :fresh_key,
    "users.restrict" => :fresh_key,
    "users.sessions.revoke" => :fresh_key,
    "gyms.read" => :key,
    "coaches.read" => :key,
    "fighters.read" => :key,
    "system.jobs.read" => :key,
    "billing.read" => :key,
    "billing.reconciliation.read" => :key,
    "config.read" => :key,
    "config.flags.write" => :fresh_key,
    "sponsors.proposals.read" => :key,
    "sponsors.proposals.claim" => :fresh_key,
    "sponsors.proposals.request_changes" => :fresh_key,
    "sponsors.proposals.accept" => :fresh_key,
    "sponsors.proposals.decline" => :fresh_key
  }

  @required_authenticators Application.compile_env(
                             :simple_fit,
                             [__MODULE__, :required_authenticators],
                             2
                           )

  if Mix.env() == :prod and @required_authenticators < 2 do
    raise "SF-110: a production build requires at least two operator security keys"
  end

  @type permission :: String.t()
  @type assurance :: :key | :fresh_key

  @doc "Every permission an operator can hold."
  @spec permissions() :: [permission()]
  def permissions, do: @permissions

  @doc "Whether `permission` is in the catalog."
  @spec permission?(term()) :: boolean()
  def permission?(permission), do: permission in @permissions

  @doc "The assurance a permission needs."
  @spec assurance(permission()) :: assurance()
  def assurance(permission), do: Map.fetch!(@assurance, permission)

  @doc "Security keys an operator must have registered to be active."
  @spec required_authenticators() :: pos_integer()
  def required_authenticators, do: @required_authenticators

  @doc "Seconds a key check stays valid in its session."
  @spec step_up_ttl() :: pos_integer()
  def step_up_ttl, do: 30 * 60

  @doc "Seconds within which a key check counts as fresh, for high-risk actions."
  @spec fresh_window() :: pos_integer()
  def fresh_window, do: 5 * 60

  @doc "Seconds an admin action confirmation (SF-111) can be used, once."
  @spec confirmation_ttl() :: pos_integer()
  def confirmation_ttl, do: 120

  @doc "Refused, conflicting or invalid admin action attempts audited per operator and hour."
  @spec refusal_audit_limit() :: pos_integer()
  def refusal_audit_limit, do: 300

  @doc "Admin action previews per operator and hour."
  @spec preview_limit() :: pos_integer()
  def preview_limit, do: 120

  @doc "Seconds an audit log cursor stays valid."
  @spec cursor_ttl() :: pos_integer()
  def cursor_ttl, do: 3600

  @doc "Seconds a WebAuthn challenge can be answered."
  @spec challenge_ttl() :: pos_integer()
  def challenge_ttl, do: 120

  @doc "Seconds a provisioned operator has to register their keys."
  @spec enrollment_window() :: pos_integer()
  def enrollment_window, do: 72 * 3600

  @doc "Seconds a bootstrapped or recovered operator has to register their keys."
  @spec ceremony_enrollment_window() :: pos_integer()
  def ceremony_enrollment_window, do: 24 * 3600

  @doc "Longest lifetime a signed ceremony statement may declare, in seconds."
  @spec statement_max_lifetime() :: pos_integer()
  def statement_max_lifetime, do: 24 * 3600
end
