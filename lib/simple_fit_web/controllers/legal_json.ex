defmodule SimpleFitWeb.LegalJSON do
  @moduledoc """
  JSON rendering of legal document references (`LegalDocumentRef`, SF-72),
  shared by every response that carries one.
  """

  def show(%{document: document}), do: %{document: ref(document)}

  @doc "A `SimpleFit.Legal.ref()` as JSON (or `nil`)."
  def ref(nil), do: nil

  def ref(document) do
    %{
      document_id: document.document_id,
      version: document.version,
      status: document.status,
      effective_at: document.effective_at && DateTime.to_iso8601(document.effective_at),
      published_at: document.published_at && DateTime.to_iso8601(document.published_at),
      requested_language: document.requested_language,
      language: document.language,
      available_languages: document.available_languages,
      content_sha256: document.content_sha256,
      title: document.title,
      summary: document.summary,
      checkbox: document.checkbox,
      full: document.full
    }
  end
end
