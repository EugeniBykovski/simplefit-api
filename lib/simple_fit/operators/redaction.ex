defmodule SimpleFit.Operators.Redaction do
  @moduledoc """
  What operator data may leave the context (SF-111, ADR 0029): allowlists, never a
  search-and-replace over secrets. Anything not listed here stays inside.

  * Audit events: ids, codes, states and times. Audit rows hold no emails, names,
    request bodies, challenges, keys, tokens or free text in the first place
    (SF-110); this list also keeps any column a later migration adds out of
    responses until it is reviewed and listed.
  * Error details: the conflict keys the API documents. A domain error can't put
    a value into a response by naming a new key.
  * Never: WebAuthn public keys, credential ids, challenge bytes, confirmation tokens
    or their hashes, request digests, IP addresses, emails.
  """

  alias SimpleFit.Operators.AuditEvent

  @audit_fields [
    :id,
    :occurred_at,
    :action,
    :command,
    :outcome,
    :result_code,
    :authority,
    :actor_operator_id,
    :actor_user_id,
    :permission,
    :target_type,
    :target_id,
    :reason_code,
    :from_state,
    :to_state,
    :revision,
    :operation_id,
    :confirmation_id,
    :session_id,
    :ceremony_id,
    :request_id
  ]

  @detail_keys [
    :target,
    :status,
    :permission,
    :operator,
    :user,
    :operation_id,
    :credentials,
    :credential,
    :required,
    :enrollment,
    :current_revision,
    # SF-116: sponsor decisions (`organization`: exists | none | active | suspended |
    # closed | invalid; `applicant`: not_eligible; `provisioning_key`: reused).
    :organization,
    :applicant,
    :provisioning_key
  ]

  @doc "The audit event fields a reader with `audit.read` sees."
  @spec audit_fields() :: [atom()]
  def audit_fields, do: @audit_fields

  @doc "An audit event as an allowlisted map (enums as strings)."
  @spec audit_event(AuditEvent.t()) :: map()
  def audit_event(%AuditEvent{} = event) do
    event
    |> Map.take(@audit_fields)
    |> Map.new(fn
      {key, value} when is_atom(value) and value not in [nil, true, false] ->
        {key, Atom.to_string(value)}

      pair ->
        pair
    end)
  end

  @doc "Conflict details reduced to the documented keys with scalar values."
  @spec details(map()) :: map()
  def details(details) when is_map(details) do
    details
    |> Map.take(@detail_keys)
    |> Map.filter(fn {_key, value} -> is_binary(value) or is_integer(value) end)
  end

  @doc """
  An email address masked for operator views (SF-122): the first character of the
  local part and the domain (`n•••@example.com`). The full address needs
  `users.reveal_email`.
  """
  @spec mask_email(String.t()) :: String.t()
  def mask_email(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] when local != "" -> String.first(local) <> "•••@" <> domain
      _ -> "•••"
    end
  end
end
