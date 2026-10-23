defmodule SimpleFit.Coaching.LegalPolicy do
  @moduledoc """
  The one place Coach–Fighter coaching asks which legal regime applies
  (ADR 0021, ADR 0022, ADR 0025). Every legal decision of the coaching
  context goes through here; nothing else reads the mode.

  * `:production_approved`: the normal regime. The sharing gate is on, the
    legal registry is valid, and the configured fighter disclosure and coach
    data rules are published (`SimpleFit.Coaching.Disclosure`). Coaches
    acknowledge the data rules; fighters accept the approved disclosure in
    the language they were shown; evidence is recorded.
  * `:local_development_bypass`: LOCAL DEVELOPMENT only
    (`SimpleFit.Coaching.LocalDevelopment`, which a production build can
    never activate). No legal document is involved, so none is shown,
    acknowledged or recorded. Coaches invite without data rules. Fighters
    accept without a disclosure text, and the acceptance records the
    marker `local_development_marker/0` instead of a version: an honest
    statement that no legal text was accepted, never a legal version. That
    marker discloses the `basic_profile` fields only while this mode is
    active; in any other mode it discloses nothing. Everything else stays
    as it is: authentication, recipient binding to a verified email
    identity, explicit acceptance, the 18+ rule, completed profiles, IDOR
    protection, replay, locking and limits.
  * `:blocked`: neither; coaching is unavailable (fail closed).
  """

  alias SimpleFit.Coaching
  alias SimpleFit.Coaching.{Disclosure, LocalDevelopment}
  alias SimpleFit.Legal.Registry

  @type mode :: :production_approved | :local_development_bypass | :blocked

  # Not a legal version: what a relationship accepted in local development
  # records in place of one (ADR 0025).
  @marker "local-development-no-legal-text"
  @marker_scope :basic_profile

  @doc "The regime that applies now."
  @spec mode() :: mode()
  def mode do
    cond do
      LocalDevelopment.active?() -> :local_development_bypass
      approved?() -> :production_approved
      true -> :blocked
    end
  end

  @doc "Whether Coach–Fighter coaching is available at all (not `:blocked`)."
  @spec available?() :: boolean()
  def available?, do: mode() != :blocked

  @doc "Whether the mode is `:local_development_bypass`."
  @spec local_development?() :: boolean()
  def local_development?, do: mode() == :local_development_bypass

  @doc "The marker a local-development acceptance records instead of a disclosure version."
  @spec local_development_marker() :: String.t()
  def local_development_marker, do: @marker

  @doc """
  What clients are told (`legal_mode`): `"approved"`, or
  `"local_development"`, in which no legal document is shown or needed.
  """
  @spec client_mode() :: String.t()
  def client_mode, do: if(local_development?(), do: "local_development", else: "approved")

  @doc """
  The disclosure a fighter is shown and must echo to accept: the current
  approved version, the local-development marker, or `nil` (unavailable).
  """
  @spec current_disclosure() :: String.t() | nil
  def current_disclosure do
    case mode() do
      :local_development_bypass -> @marker
      :production_approved -> Disclosure.current()
      :blocked -> nil
    end
  end

  @doc "Whether `version` may be accepted now."
  @spec disclosure_offered?(term()) :: boolean()
  def disclosure_offered?(version) do
    case mode() do
      :local_development_bypass -> version == @marker
      :production_approved -> Disclosure.offered?(version)
      :blocked -> false
    end
  end

  @doc """
  The fighter fields a relationship accepted under `version` discloses. The
  local-development marker discloses its scope only while that mode is
  active; any other version is the approved contract's (`Disclosure.fields/1`).
  """
  @spec disclosure_fields(String.t()) :: [atom()]
  def disclosure_fields(@marker) do
    if local_development?(),
      do: Enum.filter(Disclosure.scope_fields(@marker_scope), &(&1 in coach_visible())),
      else: []
  end

  def disclosure_fields(version) when is_binary(version), do: Disclosure.fields(version)

  @doc "The fields `current_disclosure/0` discloses (empty when unavailable)."
  @spec current_fields() :: [atom()]
  def current_fields do
    case current_disclosure() do
      nil -> []
      version -> disclosure_fields(version)
    end
  end

  @doc """
  The coach data rules a coach must acknowledge before inviting:
  `{:required, version}`, `:not_required` (local development: there are
  none), or `:unavailable`.
  """
  @spec data_rules() :: {:required, String.t()} | :not_required | :unavailable
  def data_rules do
    case mode() do
      :local_development_bypass ->
        :not_required

      :production_approved ->
        case Disclosure.data_rules_version() do
          version when is_binary(version) -> {:required, version}
          nil -> :unavailable
        end

      :blocked ->
        :unavailable
    end
  end

  @doc """
  Whether an acceptance needs the approved disclosure text in the language
  the fighter was shown, and records legal evidence (not in local
  development, where no text exists).
  """
  @spec legal_text_required?() :: boolean()
  def legal_text_required?, do: not local_development?()

  defp approved? do
    Coaching.access_enabled?() and Registry.valid?() and is_binary(Disclosure.current()) and
      is_binary(Disclosure.data_rules_version())
  end

  defp coach_visible, do: SimpleFit.Fighters.coach_visible_fields()
end
