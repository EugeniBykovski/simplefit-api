defmodule SimpleFit.Legal.Registry do
  @moduledoc """
  The registry of legal document versions (ADR 0022): a code-reviewed
  directory, never a database table, an upload or an environment variable.

      <registry_path>/registry.json
      <registry_path>/documents/<document_id>/<version>/<language>/{title,summary,checkbox,full}.md

  `registry.json` lists every version with its metadata; each language
  variant names the SHA-256 of its text (`content_sha256/1`). On load every
  rule below is checked and every text is hashed; any violation makes the
  whole registry invalid. An invalid registry never stops the application:
  it only makes `valid?/0` false, which keeps Coach–Fighter sharing
  unavailable (`SimpleFit.Coaching.sharing_ready?/0`) while sign-in and
  everything else keep working.

  Rules:

    * `document_id` is `fighter-coach-disclosure` or `coach-data-rules`.
    * `version` is `<document_id>-<YYYY>-<MM>-<seq>`; only test fixtures
      (`test_only`, accepted only where `allow_test_fixtures` is configured)
      use `<document_id>-test-<n>`. A version appears once.
    * `status` is `draft`, `approved`, `published`, `superseded` or
      `withdrawn`; at most one `published` version per document. Every status
      but `draft` needs `approval_ref`, `approved_by` and `effective_at`;
      `published`, `superseded` and `withdrawn` need `published_at`;
      `withdrawn` needs `withdrawal_notice_ref`.
    * A disclosure names its `scope` (`SimpleFit.Coaching.Disclosure`); the
      coach data rules have none.
    * Languages are product locales; English, the reference language, is
      required from `approved` on. Every part file exists and the variant's
      hash matches its text.

  The registry is read once at boot (`load/0`) into a persistent term.
  """

  require Logger

  alias SimpleFit.Coaching.Disclosure

  @key {__MODULE__, :state}
  @document_ids ~w(fighter-coach-disclosure coach-data-rules)
  @statuses ~w(draft approved published superseded withdrawn)
  @languages ~w(en pl ru uk de es es-MX fr)
  @parts ~w(title summary checkbox full)
  @max_part_bytes 200_000

  @type language :: String.t()
  @type variant :: %{
          language: language(),
          content_sha256: String.t(),
          title: String.t(),
          summary: String.t(),
          checkbox: String.t(),
          full: String.t()
        }
  @type version :: %{
          document_id: String.t(),
          version: String.t(),
          status: String.t(),
          scope: atom() | nil,
          effective_at: DateTime.t() | nil,
          published_at: DateTime.t() | nil,
          approval_ref: String.t() | nil,
          test_only: boolean(),
          languages: %{language() => variant()}
        }

  @doc "The document ids the registry accepts."
  @spec document_ids() :: [String.t()]
  def document_ids, do: @document_ids

  @doc "The product locales a variant may have."
  @spec languages() :: [language()]
  def languages, do: @languages

  @doc """
  Reads and validates the configured registry and keeps the result. Returns
  `:ok`, or `{:invalid, reason}` (logged by reason code only; no text).
  """
  @spec load() :: :ok | {:invalid, atom()}
  def load do
    state =
      case read(registry_path(), allow_test_fixtures?()) do
        {:ok, versions} -> {:ok, versions}
        {:error, reason} -> {:invalid, reason}
      end

    :persistent_term.put(@key, state)

    case state do
      {:ok, _versions} ->
        :ok

      {:invalid, reason} ->
        Logger.error("legal document registry invalid: Coach–Fighter sharing unavailable",
          reason: reason
        )

        {:invalid, reason}
    end
  end

  @doc "Whether the loaded registry is valid."
  @spec valid?() :: boolean()
  def valid?, do: match?({:ok, _}, state())

  @doc "A version of a document, or `:error` (unknown, or the registry is invalid)."
  @spec get(String.t(), String.t()) :: {:ok, version()} | :error
  def get(document_id, version) when is_binary(document_id) and is_binary(version) do
    case state() do
      {:ok, %{^document_id => %{^version => found}}} -> {:ok, found}
      _ -> :error
    end
  end

  def get(_document_id, _version), do: :error

  @doc "The `published` version of a document, or `:error`."
  @spec published(String.t()) :: {:ok, version()} | :error
  def published(document_id) do
    with {:ok, %{^document_id => versions}} <- state(),
         [found] <- versions |> Map.values() |> Enum.filter(&(&1.status == "published")) do
      {:ok, found}
    else
      _ -> :error
    end
  end

  @doc """
  The SHA-256 (lowercase hex) of a variant's text: the parts in the order
  `title`, `summary`, `checkbox`, `full`, each as its name, a newline, its
  byte size, a newline and its bytes. The same bytes always give the same
  hash; changing any part, or moving text between parts, changes it.
  """
  @spec content_sha256(%{String.t() => binary()}) :: String.t()
  def content_sha256(parts) when is_map(parts) do
    @parts
    |> Enum.map(fn part ->
      text = Map.fetch!(parts, part)
      [part, "\n", Integer.to_string(byte_size(text)), "\n", text]
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Reads the part files of one variant directory (for hashing at publication)."
  @spec read_parts(Path.t()) :: {:ok, %{String.t() => binary()}} | {:error, atom()}
  def read_parts(dir) do
    Enum.reduce_while(@parts, {:ok, %{}}, fn part, {:ok, acc} ->
      case read_part(Path.join(dir, part <> ".md")) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, part, text)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_part(path) do
    case File.read(path) do
      {:ok, text} when byte_size(text) in 1..@max_part_bytes -> utf8(text)
      {:ok, _text} -> {:error, :part_size}
      {:error, _reason} -> {:error, :part_missing}
    end
  end

  defp utf8(text), do: if(String.valid?(text), do: {:ok, text}, else: {:error, :part_not_utf8})

  defp state do
    case :persistent_term.get(@key, nil) do
      nil ->
        _ = load()
        :persistent_term.get(@key)

      state ->
        state
    end
  end

  defp registry_path do
    case Application.get_env(:simple_fit, SimpleFit.Legal, [])[:registry_path] do
      nil -> Application.app_dir(:simple_fit, "priv/legal")
      path -> path
    end
  end

  defp allow_test_fixtures?,
    do: Application.get_env(:simple_fit, SimpleFit.Legal, [])[:allow_test_fixtures] == true

  # -- Reading and validation ------------------------------------------------

  defp read(path, allow_test?) do
    with {:ok, raw} <- read_file(Path.join(path, "registry.json")),
         {:ok, %{"documents" => entries}} when is_list(entries) <- decode(raw),
         {:ok, versions} <- versions(path, entries, allow_test?),
         :ok <- one_published_each(versions) do
      {:ok, index(versions)}
    else
      {:ok, _other} -> {:error, :registry_shape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, _} -> {:error, :registry_missing}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :registry_json}
    end
  end

  defp versions(path, entries, allow_test?) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case version(path, entry, allow_test?) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> unique_versions()
  end

  defp unique_versions({:ok, versions}) do
    if versions |> Enum.uniq_by(& &1.version) |> length() == length(versions),
      do: {:ok, Enum.reverse(versions)},
      else: {:error, :duplicate_version}
  end

  defp unique_versions(error), do: error

  @fields ~w(document_id version status scope effective_at published_at approval_ref approved_by
             withdrawal_notice_ref test_only languages)

  defp version(path, entry, allow_test?) when is_map(entry) do
    with :ok <- only_known_fields(entry),
         {:ok, document_id} <- document_id(entry["document_id"]),
         {:ok, test_only} <- test_only(entry["test_only"], allow_test?),
         {:ok, version} <- version_id(entry["version"], document_id, test_only),
         {:ok, status} <- status(entry["status"]),
         {:ok, scope} <- scope(document_id, entry["scope"]),
         :ok <- approval(status, entry),
         {:ok, effective_at} <- timestamp(entry["effective_at"], status != "draft"),
         {:ok, published_at} <-
           timestamp(entry["published_at"], status in ~w(published superseded withdrawn)),
         :ok <- withdrawal(status, entry["withdrawal_notice_ref"]),
         {:ok, languages} <-
           variants(Path.join([path, "documents", document_id, version]), entry["languages"]),
         :ok <- reference_language(status, languages) do
      {:ok,
       %{
         document_id: document_id,
         version: version,
         status: status,
         scope: scope,
         effective_at: effective_at,
         published_at: published_at,
         approval_ref: entry["approval_ref"],
         test_only: test_only,
         languages: languages
       }}
    end
  end

  defp version(_path, _entry, _allow_test?), do: {:error, :entry_shape}

  defp only_known_fields(entry) do
    if Enum.all?(Map.keys(entry), &(&1 in @fields)), do: :ok, else: {:error, :unknown_field}
  end

  defp document_id(id) when id in @document_ids, do: {:ok, id}
  defp document_id(_id), do: {:error, :document_id}

  defp test_only(nil, _allow), do: {:ok, false}
  defp test_only(false, _allow), do: {:ok, false}
  defp test_only(true, true), do: {:ok, true}
  defp test_only(true, _allow), do: {:error, :test_fixture_not_allowed}
  defp test_only(_other, _allow), do: {:error, :test_only}

  defp version_id(version, document_id, test_only) when is_binary(version) do
    prefix = Regex.escape(document_id)

    pattern =
      if test_only,
        do: ~r/\A#{prefix}-test-[0-9]{1,4}\z/,
        else: ~r/\A#{prefix}-[0-9]{4}-(0[1-9]|1[0-2])-[0-9]{1,4}\z/

    if byte_size(version) <= 64 and version =~ pattern,
      do: {:ok, version},
      else: {:error, :version_format}
  end

  defp version_id(_version, _document_id, _test_only), do: {:error, :version_format}

  defp status(status) when status in @statuses, do: {:ok, status}
  defp status(_status), do: {:error, :status}

  defp scope("fighter-coach-disclosure", scope) when is_binary(scope) do
    case Disclosure.scope(scope) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, :scope}
    end
  end

  defp scope("coach-data-rules", nil), do: {:ok, nil}
  defp scope(_document_id, _scope), do: {:error, :scope}

  defp approval("draft", _entry), do: :ok

  defp approval(_status, entry) do
    with ref when is_binary(ref) and ref != "" <- entry["approval_ref"],
         [_ | _] = by <- entry["approved_by"],
         true <- Enum.all?(by, &(is_binary(&1) and &1 != "")) do
      :ok
    else
      _ -> {:error, :approval}
    end
  end

  defp timestamp(nil, false), do: {:ok, nil}

  defp timestamp(value, _required) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, 0} -> {:ok, at}
      _ -> {:error, :timestamp}
    end
  end

  defp timestamp(_value, _required), do: {:error, :timestamp}

  defp withdrawal("withdrawn", ref) when is_binary(ref) and ref != "", do: :ok
  defp withdrawal("withdrawn", _ref), do: {:error, :withdrawal_notice}
  defp withdrawal(_status, nil), do: :ok
  defp withdrawal(_status, _ref), do: {:error, :withdrawal_notice}

  defp variants(dir, languages) when is_map(languages) and map_size(languages) > 0 do
    Enum.reduce_while(languages, {:ok, %{}}, fn {language, meta}, {:ok, acc} ->
      case variant(dir, language, meta) do
        {:ok, variant} -> {:cont, {:ok, Map.put(acc, language, variant)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp variants(_dir, _languages), do: {:error, :languages}

  defp variant(dir, language, %{"content_sha256" => sha} = meta)
       when language in @languages and map_size(meta) == 1 and is_binary(sha) do
    with {:ok, parts} <- read_parts(Path.join(dir, language)) do
      if content_sha256(parts) == sha,
        do:
          {:ok,
           %{
             language: language,
             content_sha256: sha,
             title: parts["title"],
             summary: parts["summary"],
             checkbox: parts["checkbox"],
             full: parts["full"]
           }},
        else: {:error, :content_hash_mismatch}
    end
  end

  defp variant(_dir, _language, _meta), do: {:error, :language}

  defp reference_language("draft", _languages), do: :ok

  defp reference_language(_status, languages) do
    if Map.has_key?(languages, "en"), do: :ok, else: {:error, :reference_language}
  end

  defp one_published_each(versions) do
    versions
    |> Enum.filter(&(&1.status == "published"))
    |> Enum.frequencies_by(& &1.document_id)
    |> Enum.all?(fn {_id, count} -> count == 1 end)
    |> if(do: :ok, else: {:error, :several_published})
  end

  defp index(versions) do
    Map.new(@document_ids, fn id ->
      {id, versions |> Enum.filter(&(&1.document_id == id)) |> Map.new(&{&1.version, &1})}
    end)
  end
end
