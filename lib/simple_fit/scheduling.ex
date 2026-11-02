defmodule SimpleFit.Scheduling do
  @moduledoc """
  Time rules shared by the domains that schedule things (SF-82 05, D-G14):
  ADR 0023 training sessions and SF-97 gym classes. Owned by neither; it
  holds no data and knows no domain.

  * **Zones** are IANA region ids (or `UTC`) known to PostgreSQL's zone data
    (`scheduling_valid_time_zone/1` in the database): never an abbreviation,
    a fixed offset, or a `posix/`, `right/` or `Etc/` entry. No Elixir zone
    database is used (ADR 0004); every conversion runs in PostgreSQL.
  * **Instants** are RFC 3339 texts with an explicit offset, stored in UTC.
    A non-UTC offset must be the zone's offset at that instant: a time in a
    spring-forward gap cannot be expressed, and the two instants of an
    autumn repeated hour stay distinct, chosen by their offsets.
  * **Wall-clock times** (a weekly class at 18:00) are resolved in their
    zone date by date, never by adding 24-hour steps in UTC, so 18:00 stays
    18:00 across daylight-saving changes. A local time that does not exist
    on a date (gap) or exists twice (repeated hour) is reported as such; the
    caller decides, nothing is shifted or chosen silently.
  """

  alias SimpleFit.Repo

  @unlogged [log: false]

  @type resolution ::
          {:ok, DateTime.t()} | {:error, :nonexistent_local_time | :ambiguous_local_time}

  @doc "Whether `zone` is an accepted IANA zone id (see the moduledoc)."
  @spec valid_time_zone?(term()) :: boolean()
  def valid_time_zone?(zone) when is_binary(zone) do
    %{rows: [[valid?]]} = Repo.query!("SELECT scheduling_valid_time_zone($1)", [zone], @unlogged)
    valid?
  end

  def valid_time_zone?(_zone), do: false

  @doc "The UTC offset of `zone` at the instant `at`, in seconds."
  @spec zone_offset(DateTime.t(), String.t()) :: integer()
  def zone_offset(%DateTime{} = at, zone) when is_binary(zone) do
    %{rows: [[seconds]]} =
      Repo.query!(
        "SELECT extract(epoch FROM ($1::timestamptz AT TIME ZONE $2) - ($1::timestamptz AT TIME ZONE 'UTC'))::integer",
        [at, zone],
        @unlogged
      )

    seconds
  end

  @doc """
  Reads an RFC 3339 instant with its offset: `{:ok, utc, offset_seconds}`,
  `{:error, :missing_offset}` for a time without one, or `:error`.
  """
  @spec parse_instant(term()) ::
          {:ok, DateTime.t(), integer()} | {:error, :missing_offset} | :error
  def parse_instant(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, offset} -> {:ok, at, offset}
      {:error, :missing_offset} -> {:error, :missing_offset}
      {:error, _} -> :error
    end
  end

  def parse_instant(_raw), do: :error

  @doc """
  Whether `offset` (seconds) may accompany `at` in `zone`: a UTC offset
  always may; any other must be the zone's offset at that instant.
  """
  @spec offset_matches?(DateTime.t(), integer(), String.t()) :: boolean()
  def offset_matches?(_at, 0, _zone), do: true
  def offset_matches?(%DateTime{} = at, offset, zone), do: zone_offset(at, zone) == offset

  @doc "The wall-clock date and time of `at` in `zone`."
  @spec local(DateTime.t(), String.t()) :: {Date.t(), Time.t()}
  def local(%DateTime{} = at, zone) when is_binary(zone) do
    %{rows: [[%NaiveDateTime{} = local]]} =
      Repo.query!("SELECT $1::timestamptz AT TIME ZONE $2", [at, zone], @unlogged)

    {NaiveDateTime.to_date(local), NaiveDateTime.to_time(local)}
  end

  @doc """
  The instant at which the wall-clock `time` on `date` occurs in `zone`
  (see the moduledoc for the two failures).
  """
  @spec resolve_local(Date.t(), Time.t(), String.t()) :: resolution()
  def resolve_local(%Date{} = date, %Time{} = time, zone) when is_binary(zone) do
    %{rows: [[instants]]} =
      Repo.query!(
        "SELECT scheduling_resolve_local($1::date + $2::time, $3)",
        [date, time, zone],
        @unlogged
      )

    resolution(instants)
  end

  @doc """
  Expands a weekly wall-clock rule: every date from `from` to `to`
  (inclusive) whose ISO weekday (1 = Monday) is in `weekdays`, each with its
  resolution of `time` in `zone`, in date order.
  """
  @spec weekly(Date.t(), Date.t(), [1..7], Time.t(), String.t()) :: [{Date.t(), resolution()}]
  def weekly(%Date{} = from, %Date{} = to, weekdays, %Time{} = time, zone)
      when is_list(weekdays) and is_binary(zone) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT d::date, scheduling_resolve_local(d::date + $4::time, $5)
          FROM generate_series($1::date, $2::date, interval '1 day') AS d
         WHERE extract(isodow FROM d)::smallint = ANY($3::smallint[])
         ORDER BY d
        """,
        [from, to, weekdays, time, zone],
        @unlogged
      )

    Enum.map(rows, fn [date, instants] -> {date, resolution(instants)} end)
  end

  defp resolution([%DateTime{} = at]), do: {:ok, DateTime.truncate(at, :microsecond)}
  defp resolution([]), do: {:error, :nonexistent_local_time}
  defp resolution([_first, _second]), do: {:error, :ambiguous_local_time}
end
