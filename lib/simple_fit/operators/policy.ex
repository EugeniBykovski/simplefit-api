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
  @permissions ~w(operators.read operators.manage audit.read sponsors.applications.read
                  sponsors.applications.claim sponsors.applications.request_changes
                  sponsors.applications.approve sponsors.applications.reject
                  sponsors.applications.read_files sponsors.restrict)
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
    "sponsors.restrict" => :fresh_key
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
