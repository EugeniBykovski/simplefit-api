defmodule SimpleFit.Email.Message do
  @moduledoc """
  A provider-independent transactional email.

  Build messages with `new/1`, which validates them. Recipients and headers
  are checked for line breaks so caller data can never inject extra headers.
  Content (templates, localisation) is the job of the domain that sends the
  email; this struct only carries the result.
  """

  # Subjects and bodies can carry one-time codes and personal data.
  @derive {Inspect, except: [:subject, :text, :html]}
  @enforce_keys [:to, :subject]
  defstruct [:to, :subject, :text, :html, :reply_to, from: nil]

  @type t :: %__MODULE__{
          to: [String.t()],
          subject: String.t(),
          text: String.t() | nil,
          html: String.t() | nil,
          reply_to: String.t() | nil,
          from: String.t() | nil
        }

  # Resend accepts at most 50 recipients per message.
  @max_recipients 50
  @max_subject_length 998
  @address ~r/\A[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+\z/
  @mailbox ~r/\A(?:[^<>\r\n]*<(?<address>[^<>\r\n]+)>|(?<bare>[^<>\r\n]+))\z/

  @fields ~w(to subject text html reply_to from)a

  @doc """
  Builds and validates a message.

  Accepted fields: `:to` (address or list of addresses, required),
  `:subject` (required), `:text` and/or `:html` (at least one), `:reply_to`
  and `:from` (both optional; `:from` defaults to the configured sender,
  `EMAIL_FROM`). Addresses may be `a@b.c` or `Name <a@b.c>`.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, :invalid_request}
  def new(fields) do
    fields = Map.new(fields)

    message = %__MODULE__{
      to: List.wrap(fields[:to]),
      subject: fields[:subject],
      text: fields[:text],
      html: fields[:html],
      reply_to: fields[:reply_to],
      from: fields[:from]
    }

    if valid?(message), do: {:ok, message}, else: {:error, :invalid_request}
  end

  @doc "Serializes a message for an Oban job (string keys, JSON-safe)."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = message) do
    for field <- @fields, value = Map.fetch!(message, field), value != nil, into: %{} do
      {Atom.to_string(field), value}
    end
  end

  @doc "Rebuilds (and re-validates) a message serialized with `to_map/1`."
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_request}
  def from_map(map) when is_map(map) do
    @fields
    |> Enum.flat_map(fn field ->
      case Map.fetch(map, Atom.to_string(field)) do
        {:ok, value} -> [{field, value}]
        :error -> []
      end
    end)
    |> new()
  end

  @doc "Whether `value` is a single mailbox: `a@b.c` or `Name <a@b.c>`."
  @spec mailbox?(term()) :: boolean()
  def mailbox?(value) when is_binary(value) do
    case Regex.named_captures(@mailbox, value) do
      %{"address" => address} when address != "" -> Regex.match?(@address, address)
      %{"bare" => bare} -> Regex.match?(@address, bare)
      nil -> false
    end
  end

  def mailbox?(_value), do: false

  defp valid?(%__MODULE__{} = message) do
    recipients_valid?(message.to) and subject_valid?(message.subject) and
      body_valid?(message.text, message.html) and optional_mailbox?(message.reply_to) and
      optional_mailbox?(message.from)
  end

  defp recipients_valid?(to),
    do: length(to) in 1..@max_recipients and Enum.all?(to, &mailbox?/1)

  defp subject_valid?(subject) do
    is_binary(subject) and String.trim(subject) != "" and
      String.length(subject) <= @max_subject_length and
      not String.contains?(subject, ["\r", "\n"])
  end

  defp body_valid?(text, html) do
    Enum.all?([text, html], &(is_nil(&1) or is_binary(&1))) and
      Enum.any?([text, html], &(is_binary(&1) and &1 != ""))
  end

  defp optional_mailbox?(nil), do: true
  defp optional_mailbox?(value), do: mailbox?(value)
end
