defmodule SimpleFit.Gyms.MemberImport do
  @moduledoc """
  The safe foundation of member-list import (OG12; SF-95): parse a CSV,
  map its columns, validate and deduplicate the rows and classify them
  against the gym's own members and invitations, as a **dry run**. Internal
  to `SimpleFit.Gyms`.

  ## Why only a dry run

  Storing a gym's list of third parties before they have an account (an
  "unclaimed contact"), and sending them email in bulk from it, needs an
  approved legal basis and retention rule that do not exist: SF-82 keeps CSV
  import FUTURE (D-G08 "CSV import is future"; threat model T15; 01 §4.5,
  OG12). So the preview persists **nothing**: no row, contact, file, job,
  cache or audit event, and no log line with the content. The commit (and
  its idempotency key), unclaimed contacts, storing names, phones, plans or
  start dates, and bulk E07 sending stay blocked until that decision is
  approved; the response says so (`commit.available: false`).

  Nothing here creates a user, marks an address verified, links or merges
  accounts, or matches people by name: a row is classified only by its
  canonical email against this gym's own facts (an active member, a pending
  join request, a pending member invitation). The gym learns nothing about
  any account outside its own members (the same rule as inviting one
  address).

  ## Mapping

  Two SimpleFit fields: `email` (required) and `name` (optional; checked
  only for presence, never stored or sent: E07 goes without a name). Every
  other column is reported `not_imported`. Without an explicit `mapping`
  the columns are suggested from common headers (English, Polish,
  Ukrainian, Czech).

  ## Row outcomes

  `ready` (a member invitation could be sent), `missing_email`,
  `invalid_email`, `duplicate` (the same canonical address on an earlier
  line, `duplicate_of_line`), `already_member`, `request_pending`,
  `already_invited`. Addresses are returned masked.

  Owner, managers and front desk (`manage_member_enrollment`), completed
  gyms only; 30 previews per 10 minutes per user.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SimpleFit.{Accounts, RateLimit, Repo}
  alias SimpleFit.Accounts.User

  alias SimpleFit.Gyms.{
    Access,
    Csv,
    Gym,
    Member,
    MemberInvitation,
    MemberInvitations,
    Members,
    MemberSecrets
  }

  @fields ["email", "name"]

  @synonyms %{
    "email" =>
      ~w(email e-mail mail emailaddress e-mailaddress adresemail adrese-mail emailadres електроннапошта пошта),
    "name" =>
      ~w(name fullname imięinazwisko imie imię nazwisko imięnazwisko ім'я імя піб jméno jmeno jménoapříjmení member client klient)
  }

  @outcomes [
    :ready,
    :missing_email,
    :invalid_email,
    :duplicate,
    :already_member,
    :request_pending,
    :already_invited
  ]

  @doc "The row outcomes."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc "A dry-run preview of a member list (`attrs`: `csv`, optional `mapping`)."
  @spec preview(User.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def preview(%User{} = user, gym_id, attrs) when is_map(attrs) do
    result =
      with {:ok, %{gym: gym}} <- Access.authorize(user, gym_id, :manage_member_enrollment),
           :ok <- completed(gym),
           {:ok, csv, mapping} <- params(attrs),
           :ok <-
             RateLimit.hit([
               {"gym_member_import_user", MemberSecrets.rate_limit_key("user", user.id), 30, 600}
             ]),
           {:ok, parsed} <- parse(csv),
           {:ok, columns} <- columns(parsed.header, mapping) do
        {:ok, build(gym, parsed, columns)}
      end

    :telemetry.execute([:simple_fit, :gyms, :member_import, :previewed], %{count: 1}, %{
      outcome: tag(result)
    })

    result
  end

  defp completed(%Gym{setup_status: :completed}), do: :ok
  defp completed(%Gym{}), do: {:error, {:conflict, %{setup_status: "draft"}}}

  defp params(attrs) do
    changeset =
      {%{}, %{csv: :string, mapping: :map}}
      |> Changeset.cast(attrs, [:csv, :mapping], empty_values: [])
      |> Changeset.validate_required([:csv])
      |> Members.reject_unknown_fields(attrs, ["csv", "mapping"])
      |> validate_mapping()

    if changeset.valid?,
      do: {:ok, Changeset.get_field(changeset, :csv), Changeset.get_field(changeset, :mapping)},
      else: {:error, changeset}
  end

  defp validate_mapping(changeset) do
    case Changeset.get_field(changeset, :mapping) do
      nil ->
        changeset

      mapping ->
        valid? =
          Enum.all?(mapping, fn {field, column} ->
            field in @fields and (is_binary(column) or is_nil(column))
          end)

        if valid?,
          do: changeset,
          else:
            Changeset.add_error(changeset, :mapping, "maps only email and name to column names",
              validation: :format
            )
    end
  end

  defp parse(csv) do
    case Csv.parse(csv) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, csv_error(reason)}
    end
  end

  defp csv_error(reason) do
    {code, line} =
      case reason do
        {code, line} -> {code, line}
        code -> {code, nil}
      end

    message = if line, do: "#{code} at line #{line}", else: Atom.to_string(code)

    {%{}, %{csv: :string}}
    |> Changeset.change()
    |> Changeset.add_error(:csv, message, validation: code)
  end

  # `[{header, field | nil}]`, from the explicit mapping or the suggestion.
  defp columns(header, nil) do
    suggested =
      Enum.reduce(@fields, %{}, fn field, acc ->
        case Enum.find(header, &(normalize(&1) in @synonyms[field] and &1 not in Map.values(acc))) do
          nil -> acc
          column -> Map.put(acc, field, column)
        end
      end)

    columns(header, suggested)
  end

  defp columns(header, mapping) do
    mapping = Map.reject(mapping, fn {_field, column} -> is_nil(column) end)
    unknown = mapping |> Map.values() |> Enum.reject(&(&1 in header))
    by_column = Map.new(mapping, fn {field, column} -> {column, field} end)

    cond do
      unknown != [] ->
        {:error, mapping_error(:mapping, "names a column that is not in the header", :inclusion)}

      map_size(by_column) != map_size(mapping) ->
        {:error, mapping_error(:mapping, "maps two fields to one column", :format)}

      not Map.has_key?(mapping, "email") ->
        {:error, mapping_error(:email_column, "must be mapped to a column", :required)}

      true ->
        {:ok, Enum.map(header, &{&1, Map.get(by_column, &1)})}
    end
  end

  defp mapping_error(field, message, validation) do
    {%{}, %{field => :string}}
    |> Changeset.change()
    |> Changeset.add_error(field, message, validation: validation)
  end

  defp normalize(header),
    do: header |> String.downcase() |> String.replace(~r/[\s_.]/u, "")

  ## Classification

  defp build(gym, parsed, columns) do
    email_at = Enum.find_index(columns, &(elem(&1, 1) == "email"))
    name_at = Enum.find_index(columns, &(elem(&1, 1) == "name"))

    read =
      Enum.map(parsed.rows, fn {line, fields} ->
        raw = fields |> Enum.at(email_at, "") |> String.trim()
        name? = name_at != nil and String.trim(Enum.at(fields, name_at, "")) != ""

        address =
          cond do
            raw == "" ->
              :missing

            match?({:ok, _}, Accounts.normalize_email(raw)) ->
              elem(Accounts.normalize_email(raw), 1)

            true ->
              :invalid
          end

        %{line: line, address: address, name_present: name?}
      end)

    addresses = for %{address: a} when is_binary(a) <- read, uniq: true, do: a
    facts = facts(gym.id, addresses)

    {rows, _seen} =
      Enum.map_reduce(read, %{}, fn row, seen ->
        classify(row, seen, facts)
      end)

    %{
      persisted: false,
      commit: %{available: false, blocked_by: "legal_basis_pending"},
      delimiter: parsed.delimiter,
      columns:
        Enum.map(columns, fn {header, field} ->
          %{header: header, field: field, status: if(field, do: :mapped, else: :not_imported)}
        end),
      summary: summary(rows),
      rows: rows
    }
  end

  defp classify(%{address: :missing} = row, seen, _facts),
    do: {result(row, :missing_email, nil), seen}

  defp classify(%{address: :invalid} = row, seen, _facts),
    do: {result(row, :invalid_email, nil), seen}

  defp classify(%{address: address, line: line} = row, seen, facts) do
    outcome =
      cond do
        Map.has_key?(seen, address) -> {:duplicate, seen[address]}
        Map.get(facts.members, address) == :active -> :already_member
        Map.get(facts.members, address) == :requested -> :request_pending
        MapSet.member?(facts.invited, address) -> :already_invited
        true -> :ready
      end

    case outcome do
      {:duplicate, first} -> {result(row, :duplicate, first), seen}
      outcome -> {result(row, outcome, nil), Map.put(seen, address, line)}
    end
  end

  defp result(row, outcome, duplicate_of) do
    %{
      line: row.line,
      email: if(is_binary(row.address), do: MemberInvitations.mask(row.address)),
      name_present: row.name_present,
      outcome: outcome,
      duplicate_of_line: duplicate_of
    }
  end

  # This gym's own facts about the list's addresses, in three queries.
  defp facts(_gym_id, []), do: %{members: %{}, invited: MapSet.new()}

  defp facts(gym_id, addresses) do
    users = Accounts.users_by_email_identity(addresses)

    statuses =
      Repo.all(
        from(m in Member,
          where:
            m.gym_id == ^gym_id and m.user_id in ^Map.values(users) and
              m.status in [:requested, :active],
          select: {m.user_id, m.status}
        ),
        log: false
      )
      |> Map.new()

    digests = Map.new(addresses, &{MemberSecrets.recipient_digest(&1), &1})
    now = DateTime.utc_now()

    invited =
      Repo.all(
        from(i in MemberInvitation,
          where:
            i.gym_id == ^gym_id and i.status == :pending and i.expires_at > ^now and
              i.recipient_digest in ^Map.keys(digests),
          select: i.recipient_digest
        ),
        log: false
      )
      |> MapSet.new(&Map.fetch!(digests, &1))

    members =
      for {address, user_id} <- users,
          status = statuses[user_id],
          into: %{},
          do: {address, status}

    %{members: members, invited: invited}
  end

  defp summary(rows) do
    counts = Enum.frequencies_by(rows, & &1.outcome)
    Map.new(@outcomes, &{&1, Map.get(counts, &1, 0)}) |> Map.put(:total, length(rows))
  end

  defp tag({:ok, _}), do: :ok
  defp tag({:error, %Changeset{}}), do: :validation_error
  defp tag({:error, {:conflict, _}}), do: :conflict
  defp tag({:error, {:rate_limited, _}}), do: :rate_limited
  defp tag({:error, reason}) when is_atom(reason), do: reason
end
