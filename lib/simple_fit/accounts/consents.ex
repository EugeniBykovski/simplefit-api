defmodule SimpleFit.Accounts.Consents do
  @moduledoc """
  Current consent state derived from the append-only history (ADR 0016).

  The current version of each required legal document comes from
  configuration (`config :simple_fit, SimpleFit.Accounts.Consents,
  current_versions: %{terms: "terms-v1", privacy: "privacy-v1"}`): an
  acceptance counts as current only for the configured version, so changing
  it makes earlier acceptances not current. That gates initial registration
  completion only; a completed registration stays complete and `current:
  false` is the hook for a future re-consent flow. Document text is not part
  of the domain. Internal to `SimpleFit.Accounts`.
  """

  import Ecto.Query, only: [from: 2]

  alias SimpleFit.Accounts.AccountConsent
  alias SimpleFit.Repo

  @unlogged [log: false]

  @typedoc "State of one required legal consent."
  @type legal :: %{
          accepted: boolean(),
          accepted_version: String.t() | nil,
          accepted_at: DateTime.t() | nil,
          current_version: String.t(),
          current: boolean()
        }

  @typedoc "Consent state of a user."
  @type state :: %{
          terms: legal(),
          privacy: legal(),
          product_news: %{subscribed: boolean(), updated_at: DateTime.t() | nil}
        }

  @doc "The configured current version of a required document."
  @spec current_version(:terms | :privacy) :: String.t()
  def current_version(kind) when kind in [:terms, :privacy] do
    :simple_fit
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:current_versions)
    |> Map.fetch!(kind)
  end

  @doc "The consent state of a user, from their history."
  @spec state(Ecto.UUID.t()) :: state()
  def state(user_id) when is_binary(user_id) do
    history =
      Repo.all(
        from(c in AccountConsent,
          where: c.user_id == ^user_id,
          order_by: [asc: c.recorded_at, asc: c.id]
        ),
        @unlogged
      )

    %{
      terms: legal_state(history, :terms),
      privacy: legal_state(history, :privacy),
      product_news: product_news_state(history)
    }
  end

  @doc "Required consents not accepted at their current version."
  @spec missing(state()) :: [:terms | :privacy]
  def missing(state), do: Enum.reject([:terms, :privacy], &state[&1].current)

  @doc """
  The history records a save must append: an acceptance of a required
  document not yet accepted at its current version, and a product-news
  decision that differs from the current one. Repeating a current decision
  appends nothing.
  """
  @spec records_for(Ecto.UUID.t(), map(), state(), DateTime.t()) :: [map()]
  def records_for(user_id, changes, state, now) do
    legal =
      for {field, kind} <- [accept_terms: :terms, accept_privacy: :privacy],
          Map.get(changes, field) == true,
          not state[kind].current do
        record(user_id, kind, current_version(kind), :accepted, now)
      end

    news =
      case Map.fetch(changes, :product_news) do
        {:ok, subscribe}
        when is_boolean(subscribe) and subscribe != state.product_news.subscribed ->
          [
            record(
              user_id,
              :product_news,
              nil,
              if(subscribe, do: :accepted, else: :withdrawn),
              now
            )
          ]

        _unchanged ->
          []
      end

    legal ++ news
  end

  @doc "Appends history records (inside the caller's transaction)."
  @spec append([map()]) :: :ok
  def append([]), do: :ok

  def append(records) do
    {_count, nil} = Repo.insert_all(AccountConsent, records, @unlogged)
    :ok
  end

  defp record(user_id, kind, version, decision, now) do
    %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      kind: kind,
      document_version: version,
      decision: decision,
      recorded_at: now
    }
  end

  defp legal_state(history, kind) do
    current_version = current_version(kind)
    accepted = Enum.filter(history, &(&1.kind == kind and &1.decision == :accepted))
    current = Enum.find(Enum.reverse(accepted), &(&1.document_version == current_version))
    latest = List.last(accepted)

    %{
      accepted: latest != nil,
      accepted_version: latest && latest.document_version,
      accepted_at: latest && latest.recorded_at,
      current_version: current_version,
      current: current != nil
    }
  end

  defp product_news_state(history) do
    case history |> Enum.filter(&(&1.kind == :product_news)) |> List.last() do
      nil -> %{subscribed: false, updated_at: nil}
      latest -> %{subscribed: latest.decision == :accepted, updated_at: latest.recorded_at}
    end
  end
end
