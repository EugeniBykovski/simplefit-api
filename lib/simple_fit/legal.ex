defmodule SimpleFit.Legal do
  @moduledoc """
  Legal documents and the evidence of their acceptance (ADR 0022; SF-71).

  Documents come only from the code-reviewed registry
  (`SimpleFit.Legal.Registry`); this context never invents a text, a version
  or a URL and has no way to change one at run time. Engineering approval of
  this mechanism is not legal approval of any text: a version is acceptable
  only when the registry records it `published`, with its approval
  reference.

  A version has one id for all its language variants; each variant has its
  own text and hash. Four languages are distinct and never conflated: the
  app's UI language, the language a client requests, the language actually
  presented (only an approved variant, never a fallback), and the language
  recorded in the evidence (the presented one).
  """

  alias SimpleFit.Legal.{Evidence, Registry}
  alias SimpleFit.Repo

  @unlogged [log: false]

  @typedoc "A document reference for a client: metadata and, when available, the variant's text."
  @type ref :: %{
          document_id: String.t(),
          version: String.t(),
          status: String.t(),
          effective_at: DateTime.t() | nil,
          published_at: DateTime.t() | nil,
          requested_language: String.t() | nil,
          language: String.t() | nil,
          available_languages: [String.t()],
          content_sha256: String.t() | nil,
          title: String.t() | nil,
          summary: String.t() | nil,
          checkbox: String.t() | nil,
          full: String.t() | nil
        }

  @doc "The approved variant of `version` in `language`, or `:error` (no such variant)."
  @spec variant(String.t(), String.t(), term()) :: {:ok, Registry.variant()} | :error
  def variant(document_id, version, language) when is_binary(language) do
    case Registry.get(document_id, version) do
      {:ok, %{languages: %{^language => variant}}} -> {:ok, variant}
      _ -> :error
    end
  end

  def variant(_document_id, _version, _language), do: :error

  @doc """
  A reference to `version` for a client that requested `language`: always
  the metadata and the approved languages; the text only when an approved
  variant in exactly that language exists (never a fallback).
  """
  @spec ref(String.t(), String.t() | nil, term()) :: {:ok, ref()} | :error
  def ref(document_id, version, language) do
    case Registry.get(document_id, version) do
      {:ok, found} -> {:ok, to_ref(found, requested(language))}
      :error -> :error
    end
  end

  defp requested(language) when is_binary(language) do
    if language in Registry.languages(), do: language
  end

  defp requested(_language), do: nil

  @no_text %{
    language: nil,
    content_sha256: nil,
    title: nil,
    summary: nil,
    checkbox: nil,
    full: nil
  }

  defp to_ref(found, requested) do
    text =
      case Map.fetch(found.languages, requested) do
        {:ok, variant} -> Map.take(variant, Map.keys(@no_text))
        :error -> @no_text
      end

    Map.merge(text, %{
      document_id: found.document_id,
      version: found.version,
      status: found.status,
      effective_at: found.effective_at,
      published_at: found.published_at,
      requested_language: requested,
      available_languages: found.languages |> Map.keys() |> Enum.sort()
    })
  end

  @doc """
  A document for the public pages: its `published` version (`version` =
  `:current`) or a named `published` or `superseded` one (an archive).
  Drafts, approved-but-unpublished and withdrawn versions are `:not_found`,
  as is everything while the registry is invalid.
  """
  @spec public_document(String.t(), String.t() | :current, term()) ::
          {:ok, ref()} | {:error, :not_found}
  def public_document(document_id, :current, language) do
    case Registry.published(document_id) do
      {:ok, found} -> public_document(document_id, found.version, language)
      :error -> {:error, :not_found}
    end
  end

  def public_document(document_id, version, language) when is_binary(version) do
    case Registry.get(document_id, version) do
      {:ok, %{status: status} = found} when status in ["published", "superseded"] ->
        {:ok, to_ref(found, requested(language))}

      _ ->
        {:error, :not_found}
    end
  end

  def public_document(_document_id, _version, _language), do: {:error, :not_found}

  @doc """
  Records a fighter's acceptance of the disclosure `variant` (inside the
  caller's transaction). One per invitation.
  """
  @spec record_acceptance!(map()) :: :ok
  def record_acceptance!(%{
        fighter_user_id: fighter,
        coach_user_id: coach,
        invitation_id: invitation,
        relationship_id: relationship,
        version: version,
        variant: variant
      }) do
    insert!(%{
      kind: :fighter_disclosure_acceptance,
      subject_user_id: fighter,
      counterparty_user_id: coach,
      invitation_id: invitation,
      relationship_id: relationship,
      document_id: "fighter-coach-disclosure",
      document_version: version,
      document_language: variant.language,
      content_sha256: variant.content_sha256
    })
  end

  @doc "Records a coach's acknowledgement of the data-rules `variant` (inside the caller's transaction)."
  @spec record_acknowledgement!(map()) :: :ok
  def record_acknowledgement!(%{coach_user_id: coach, version: version, variant: variant}) do
    insert!(%{
      kind: :coach_data_rules_acknowledgement,
      subject_user_id: coach,
      counterparty_user_id: nil,
      invitation_id: nil,
      relationship_id: nil,
      document_id: "coach-data-rules",
      document_version: version,
      document_language: variant.language,
      content_sha256: variant.content_sha256
    })
  end

  defp insert!(attrs) do
    {1, _} =
      Repo.insert_all(
        Evidence,
        [Map.merge(attrs, %{id: Ecto.UUID.generate(), recorded_at: DateTime.utc_now()})],
        @unlogged
      )

    :ok
  end
end
