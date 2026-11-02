defmodule SimpleFit.Repo.Migrations.CreateGymClasses do
  use Ecto.Migration

  # SF-97: gym classes and the timetable (ADR 0026, D-G14, D-G15; SF-82 05).
  #
  # Four tables, all under one gym:
  #
  # * `gym_venues` - a bookable training area (room, ring, hall) at one of
  #   the gym's own locations, with its IANA time zone and an optional
  #   capacity. Every class takes place in exactly one venue, and every venue
  #   is exclusive: two scheduled classes never overlap in it.
  # * `gym_class_templates` - a reusable class definition (title and
  #   defaults). Not a scheduled class.
  # * `gym_class_series` - a bounded weekly rule (weekdays, local start time,
  #   duration, first and last date) in its venue's zone, fully materialized
  #   into occurrences.
  # * `gym_class_occurrences` - an actual dated class: UTC instants, the zone
  #   and local identity it was scheduled with, venue, instructor, capacity,
  #   status. One-time classes have no series.
  #
  # Tenancy is structural: every reference to a venue, template, series,
  # location or staff membership is a composite foreign key that includes
  # `gym_id`, so a row of another gym cannot be attached. Overlaps are
  # refused by PostgreSQL exclusion constraints on half-open `[starts_at,
  # ends_at)` ranges of scheduled occurrences (per venue, and per instructor
  # across every gym). Nothing here references TrainingSessions, Coach–Fighter
  # relationships, gym members, bookings or attendance. Rows are never
  # deleted (cancelled rows stay as history).
  def up do
    # Equality on uuid columns inside a GiST exclusion constraint.
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

    # -- Shared scheduling rules (SimpleFit.Scheduling) --------------------------

    # The ADR 0023 zone rule, shared: an IANA region id (or UTC) known to this
    # server's zone data; never an abbreviation or a POSIX, right/ or Etc/ entry.
    execute("""
    CREATE FUNCTION scheduling_valid_time_zone(zone text) RETURNS boolean AS $$
      SELECT zone IS NOT NULL
        AND (zone = 'UTC' OR (zone ~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$'
                              AND zone !~ '^(posix|right|Etc)/'))
        AND EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = zone)
    $$ LANGUAGE sql STABLE
    """)

    # Every instant at which the wall-clock time `local` occurs in `zone`,
    # in order: none in a spring-forward gap, two in an autumn repeated hour,
    # one otherwise. The zone's offsets one day before and after are the
    # only candidates (no zone changes its offset twice within a day).
    execute("""
    CREATE FUNCTION scheduling_resolve_local(local timestamp, zone text)
    RETURNS timestamptz[] AS $$
      SELECT coalesce(array_agg(DISTINCT cand ORDER BY cand), '{}')
      FROM (
        SELECT (local - ((probe AT TIME ZONE zone) - (probe AT TIME ZONE 'UTC')))
                 AT TIME ZONE 'UTC' AS cand
        FROM (VALUES ((local - interval '1 day') AT TIME ZONE 'UTC'),
                     ((local + interval '1 day') AT TIME ZONE 'UTC')) AS p(probe)
      ) c
      WHERE (cand AT TIME ZONE zone) = local
    $$ LANGUAGE sql STABLE
    """)

    # ISO weekdays (1 = Monday ... 7 = Sunday), at least one, no repeats.
    execute("""
    CREATE FUNCTION scheduling_valid_weekdays(days smallint[]) RETURNS boolean AS $$
      SELECT days IS NOT NULL
        AND cardinality(days) BETWEEN 1 AND 7
        AND days <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]
        AND cardinality(days) = (SELECT count(DISTINCT d) FROM unnest(days) AS d)
    $$ LANGUAGE sql IMMUTABLE
    """)

    # Targets of the composite (tenant) foreign keys below.
    create unique_index(:gym_locations, [:gym_id, :id], name: :gym_locations_gym_id_id_index)

    # -- Venues ------------------------------------------------------------------

    create table(:gym_venues) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :gym_location_id,
          references(:gym_locations,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :name, :text, null: false
      add :description, :text
      # Optional: the most people the area holds; caps every class in it.
      add :capacity, :integer
      add :time_zone, :text, null: false
      add :status, :text, null: false, default: "active"
      add :deactivated_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      add :client_request_id, :binary_id, null: false
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_venues, [:gym_id, :id], name: :gym_venues_gym_id_id_index)
    create unique_index(:gym_venues, [:gym_id, :client_request_id])

    create unique_index(:gym_venues, [:gym_id, "lower(name)"],
             where: "status = 'active'",
             name: :gym_venues_active_name_index
           )

    create constraint(:gym_venues, :status_values, check: "status IN ('active', 'inactive')")

    create constraint(:gym_venues, :deactivation,
             check: "(status = 'inactive') = (deactivated_at IS NOT NULL)"
           )

    create constraint(:gym_venues, :name_length,
             check: "char_length(name) BETWEEN 1 AND 80 AND name = btrim(name)"
           )

    create constraint(:gym_venues, :description_length,
             check: "description IS NULL OR char_length(description) BETWEEN 1 AND 500"
           )

    create constraint(:gym_venues, :capacity_range,
             check: "capacity IS NULL OR capacity BETWEEN 1 AND 500"
           )

    create constraint(:gym_venues, :time_zone_valid,
             check: "scheduling_valid_time_zone(time_zone)"
           )

    create constraint(:gym_venues, :revision_positive, check: "revision >= 1")

    # -- Templates ---------------------------------------------------------------

    create table(:gym_class_templates) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :description, :text
      add :default_duration_minutes, :integer, null: false
      add :default_capacity, :integer, null: false

      add :default_venue_id,
          references(:gym_venues, with: [gym_id: :gym_id], match: :simple, on_delete: :nothing)

      add :default_instructor_staff_membership_id,
          references(:gym_staff_memberships,
            with: [gym_id: :gym_id],
            match: :simple,
            on_delete: :nothing
          )

      add :status, :text, null: false, default: "active"
      add :archived_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      add :client_request_id, :binary_id, null: false
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_class_templates, [:gym_id, :id],
             name: :gym_class_templates_gym_id_id_index
           )

    create unique_index(:gym_class_templates, [:gym_id, :client_request_id])

    create constraint(:gym_class_templates, :status_values,
             check: "status IN ('active', 'archived')"
           )

    create constraint(:gym_class_templates, :archival,
             check: "(status = 'archived') = (archived_at IS NOT NULL)"
           )

    create constraint(:gym_class_templates, :title_length,
             check: "char_length(title) BETWEEN 1 AND 80 AND title = btrim(title)"
           )

    create constraint(:gym_class_templates, :description_length,
             check: "description IS NULL OR char_length(description) BETWEEN 1 AND 1000"
           )

    create constraint(:gym_class_templates, :duration_range,
             check: "default_duration_minutes BETWEEN 5 AND 480"
           )

    create constraint(:gym_class_templates, :capacity_range,
             check: "default_capacity BETWEEN 1 AND 500"
           )

    create constraint(:gym_class_templates, :revision_positive, check: "revision >= 1")

    # -- Series --------------------------------------------------------------------

    create table(:gym_class_series) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :template_id,
          references(:gym_class_templates,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :venue_id,
          references(:gym_venues, with: [gym_id: :gym_id], match: :full, on_delete: :nothing),
          null: false

      add :instructor_staff_membership_id,
          references(:gym_staff_memberships,
            with: [gym_id: :gym_id],
            match: :simple,
            on_delete: :nothing
          )

      # The venue's zone when the series was created; the wall-clock rule is
      # expanded in it.
      add :time_zone, :text, null: false
      add :weekdays, {:array, :smallint}, null: false
      add :local_start_time, :time, null: false
      add :duration_minutes, :integer, null: false
      add :capacity, :integer, null: false
      add :starts_on, :date, null: false
      add :ends_on, :date, null: false
      add :status, :text, null: false, default: "active"
      add :cancelled_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      add :client_request_id, :binary_id, null: false
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_class_series, [:gym_id, :id],
             name: :gym_class_series_gym_id_id_index
           )

    create unique_index(:gym_class_series, [:gym_id, :client_request_id])
    create index(:gym_class_series, [:gym_id, :starts_on])

    create constraint(:gym_class_series, :status_values,
             check: "status IN ('active', 'cancelled')"
           )

    create constraint(:gym_class_series, :cancellation,
             check: "(status = 'cancelled') = (cancelled_at IS NOT NULL)"
           )

    create constraint(:gym_class_series, :weekdays_valid,
             check: "scheduling_valid_weekdays(weekdays)"
           )

    # Bounded: at most a year of dates, so the whole series is materialized.
    create constraint(:gym_class_series, :date_range,
             check: "ends_on >= starts_on AND ends_on <= starts_on + 365"
           )

    create constraint(:gym_class_series, :duration_range,
             check: "duration_minutes BETWEEN 5 AND 480"
           )

    create constraint(:gym_class_series, :capacity_range, check: "capacity BETWEEN 1 AND 500")

    create constraint(:gym_class_series, :time_zone_valid,
             check: "scheduling_valid_time_zone(time_zone)"
           )

    create constraint(:gym_class_series, :revision_positive, check: "revision >= 1")

    # -- Occurrences -----------------------------------------------------------------

    create table(:gym_class_occurrences) do
      add :gym_id, references(:gyms, on_delete: :delete_all), null: false

      add :template_id,
          references(:gym_class_templates,
            with: [gym_id: :gym_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :series_id,
          references(:gym_class_series,
            with: [gym_id: :gym_id],
            match: :simple,
            on_delete: :nothing
          )

      # The series date this occurrence is (its stable identity in the series),
      # kept when the occurrence is moved to another time.
      add :series_local_date, :date

      add :venue_id,
          references(:gym_venues, with: [gym_id: :gym_id], match: :full, on_delete: :nothing),
          null: false

      add :instructor_staff_membership_id,
          references(:gym_staff_memberships,
            with: [gym_id: :gym_id],
            match: :simple,
            on_delete: :nothing
          )

      # Set by the database from the instructor's membership: the person, so
      # one instructor is never in two overlapping classes, at any gym.
      add :instructor_user_id, :binary_id
      # When the instructor lost their staff access or eligibility and was
      # taken off this class (it needs reassignment).
      add :instructor_released_at, :utc_datetime_usec

      add :title, :text, null: false
      add :time_zone, :text, null: false
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :duration_minutes, :integer, null: false
      add :capacity, :integer, null: false
      add :status, :text, null: false, default: "scheduled"
      add :cancelled_at, :utc_datetime_usec
      add :cancel_reason, :text
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)
      # When this series occurrence was changed on its own (an exception).
      add :rescheduled_at, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      # One-time classes only (a series creates its own occurrences).
      add :client_request_id, :binary_id
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gym_class_occurrences, [:series_id, :series_local_date],
             name: :gym_class_occurrences_series_date_index
           )

    create unique_index(:gym_class_occurrences, [:gym_id, :client_request_id],
             where: "client_request_id IS NOT NULL",
             name: :gym_class_occurrences_request_index
           )

    create index(:gym_class_occurrences, [:gym_id, :starts_at, :id])
    create index(:gym_class_occurrences, [:instructor_staff_membership_id])

    create constraint(:gym_class_occurrences, :status_values,
             check: "status IN ('scheduled', 'cancelled')"
           )

    create constraint(:gym_class_occurrences, :cancellation,
             check:
               "(status = 'cancelled') = (cancelled_at IS NOT NULL) AND " <>
                 "(status = 'cancelled') = (cancel_reason IS NOT NULL) AND " <>
                 "(cancel_reason IS NULL OR cancel_reason IN ('cancelled', 'series_changed', 'series_cancelled'))"
           )

    create constraint(:gym_class_occurrences, :series_identity,
             check: "(series_id IS NULL) = (series_local_date IS NULL)"
           )

    create constraint(:gym_class_occurrences, :one_time_request,
             check: "series_id IS NULL OR client_request_id IS NULL"
           )

    create constraint(:gym_class_occurrences, :instructor_pair,
             check:
               "(instructor_staff_membership_id IS NULL) = (instructor_user_id IS NULL) AND " <>
                 "(instructor_released_at IS NULL OR instructor_staff_membership_id IS NULL)"
           )

    create constraint(:gym_class_occurrences, :title_length,
             check: "char_length(title) BETWEEN 1 AND 80"
           )

    create constraint(:gym_class_occurrences, :duration_range,
             check: "duration_minutes BETWEEN 5 AND 480"
           )

    # Elapsed time: the class ends exactly `duration_minutes` after it starts,
    # whatever the wall clock does in between.
    create constraint(:gym_class_occurrences, :interval,
             check: "ends_at - starts_at = make_interval(mins => duration_minutes)"
           )

    create constraint(:gym_class_occurrences, :capacity_range,
             check: "capacity BETWEEN 1 AND 500"
           )

    create constraint(:gym_class_occurrences, :time_zone_valid,
             check: "scheduling_valid_time_zone(time_zone)"
           )

    create constraint(:gym_class_occurrences, :revision_positive, check: "revision >= 1")

    # Two scheduled classes never share a venue at the same time; touching
    # intervals ([18:00, 19:00) and [19:00, 20:00)) do not overlap.
    execute("""
    ALTER TABLE gym_class_occurrences ADD CONSTRAINT gym_class_occurrences_venue_overlap
      EXCLUDE USING gist (venue_id WITH =, tsrange(starts_at, ends_at, '[)') WITH &&)
      WHERE (status = 'scheduled') DEFERRABLE INITIALLY IMMEDIATE
    """)

    # One person instructs at most one scheduled class at a time, across gyms.
    # Both are checked per statement; a series change, which moves many rows
    # at once, defers them to the end of its own work (SET CONSTRAINTS) so a
    # row is never compared with a sibling's old position.
    execute("""
    ALTER TABLE gym_class_occurrences ADD CONSTRAINT gym_class_occurrences_instructor_overlap
      EXCLUDE USING gist (instructor_user_id WITH =, tsrange(starts_at, ends_at, '[)') WITH &&)
      WHERE (status = 'scheduled' AND instructor_user_id IS NOT NULL)
      DEFERRABLE INITIALLY IMMEDIATE
    """)

    # -- Triggers ----------------------------------------------------------------------

    # An instructor is an active owner, manager or coach of the gym (front
    # desk never instructs; a CoachProfile alone grants nothing). Returns the
    # person (user id).
    execute("""
    CREATE FUNCTION gym_class_instructor(gym uuid, membership uuid) RETURNS uuid AS $$
    DECLARE
      person uuid;
    BEGIN
      SELECT user_id INTO person FROM gym_staff_memberships
       WHERE id = membership AND gym_id = gym AND status = 'active'
         AND role IN ('owner', 'manager', 'coach')
       FOR SHARE;

      IF person IS NULL THEN
        RAISE EXCEPTION 'not an eligible instructor of this gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_instructor_eligible';
      END IF;

      RETURN person;
    END
    $$ LANGUAGE plpgsql
    """)

    # A venue of a completed gym, at one of its non-archived locations.
    execute("""
    CREATE FUNCTION gym_venues_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed') THEN
          RAISE EXCEPTION 'venues belong to completed gyms'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_venues_completed_gym';
        END IF;
      ELSE
        IF NEW.gym_id <> OLD.gym_id OR NEW.client_request_id <> OLD.client_request_id
           OR NEW.time_zone <> OLD.time_zone THEN
          RAISE EXCEPTION 'a venue keeps its gym, zone and request'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_venues_immutable';
        END IF;
        IF OLD.status = 'inactive' AND NEW.status = 'active' THEN
          RAISE EXCEPTION 'an inactive venue stays inactive'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_venues_immutable';
        END IF;
        -- The capacity may not fall below a class still to come in it.
        IF NEW.capacity IS NOT NULL AND (OLD.capacity IS NULL OR NEW.capacity < OLD.capacity)
           AND EXISTS (SELECT 1 FROM gym_class_occurrences
                        WHERE venue_id = NEW.id AND status = 'scheduled'
                          AND starts_at > (now() AT TIME ZONE 'UTC') AND capacity > NEW.capacity) THEN
          RAISE EXCEPTION 'a class still to come exceeds the new venue capacity'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_venues_capacity_in_use';
        END IF;
      END IF;

      IF NEW.status = 'active' AND NOT EXISTS (
           SELECT 1 FROM gym_locations
            WHERE id = NEW.gym_location_id AND gym_id = NEW.gym_id AND archived_at IS NULL) THEN
        RAISE EXCEPTION 'a venue is at an active location of its gym'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_venues_location';
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_venues_guard BEFORE INSERT OR UPDATE ON gym_venues
    FOR EACH ROW EXECUTE FUNCTION gym_venues_guard()
    """)

    execute("""
    CREATE FUNCTION gym_class_templates_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed') THEN
          RAISE EXCEPTION 'class templates belong to completed gyms'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_templates_completed_gym';
        END IF;
      ELSE
        IF NEW.gym_id <> OLD.gym_id OR NEW.client_request_id <> OLD.client_request_id THEN
          RAISE EXCEPTION 'a class template keeps its gym and request'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_templates_immutable';
        END IF;
        IF OLD.status = 'archived' AND NEW.status = 'active' THEN
          RAISE EXCEPTION 'an archived class template stays archived'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_templates_immutable';
        END IF;
      END IF;

      IF NEW.default_instructor_staff_membership_id IS NOT NULL AND (TG_OP = 'INSERT'
         OR NEW.default_instructor_staff_membership_id IS DISTINCT FROM OLD.default_instructor_staff_membership_id) THEN
        PERFORM gym_class_instructor(NEW.gym_id, NEW.default_instructor_staff_membership_id);
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_class_templates_guard BEFORE INSERT OR UPDATE ON gym_class_templates
    FOR EACH ROW EXECUTE FUNCTION gym_class_templates_guard()
    """)

    execute("""
    CREATE FUNCTION gym_class_series_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed') THEN
          RAISE EXCEPTION 'class series belong to completed gyms'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_series_completed_gym';
        END IF;
      ELSE
        IF NEW.gym_id <> OLD.gym_id OR NEW.client_request_id <> OLD.client_request_id
           OR NEW.template_id <> OLD.template_id OR NEW.time_zone <> OLD.time_zone THEN
          RAISE EXCEPTION 'a class series keeps its gym, template, zone and request'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_series_immutable';
        END IF;
        IF OLD.status = 'cancelled' THEN
          RAISE EXCEPTION 'a cancelled class series is final'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_series_immutable';
        END IF;
      END IF;

      IF NEW.instructor_staff_membership_id IS NOT NULL AND (TG_OP = 'INSERT'
         OR NEW.instructor_staff_membership_id IS DISTINCT FROM OLD.instructor_staff_membership_id) THEN
        PERFORM gym_class_instructor(NEW.gym_id, NEW.instructor_staff_membership_id);
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_class_series_guard BEFORE INSERT OR UPDATE ON gym_class_series
    FOR EACH ROW EXECUTE FUNCTION gym_class_series_guard()
    """)

    # Occurrences: a completed gym's active venue and template; the instructor
    # eligible (and the person derived from the membership, never the client);
    # the capacity within the venue's; identity fields fixed; a cancelled class
    # final, except one the series rule itself took away (`series_changed`),
    # which the rule may bring back.
    execute("""
    CREATE FUNCTION gym_class_occurrences_guard() RETURNS trigger AS $$
    DECLARE
      venue_capacity integer;
      venue_status text;
      reassigned boolean;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM gyms WHERE id = NEW.gym_id AND setup_status = 'completed') THEN
          RAISE EXCEPTION 'classes belong to completed gyms'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_completed_gym';
        END IF;
        IF NEW.status <> 'scheduled' THEN
          RAISE EXCEPTION 'a class starts scheduled'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_transition';
        END IF;
      ELSE
        IF NEW.gym_id <> OLD.gym_id OR NEW.template_id <> OLD.template_id
           OR NEW.series_id IS DISTINCT FROM OLD.series_id
           OR NEW.series_local_date IS DISTINCT FROM OLD.series_local_date
           OR NEW.client_request_id IS DISTINCT FROM OLD.client_request_id
           OR NEW.time_zone <> OLD.time_zone THEN
          RAISE EXCEPTION 'a class keeps its gym, template, series identity, zone and request'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_immutable';
        END IF;
        IF OLD.status = 'cancelled' AND NOT (OLD.cancel_reason = 'series_changed'
           AND NEW.status = 'scheduled') THEN
          IF NEW.status <> 'cancelled' OR NEW.starts_at <> OLD.starts_at
             OR NEW.venue_id <> OLD.venue_id OR NEW.capacity <> OLD.capacity
             OR NEW.duration_minutes <> OLD.duration_minutes THEN
            RAISE EXCEPTION 'a cancelled class is final'
              USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_transition';
          END IF;
        END IF;
      END IF;

      IF NEW.status = 'scheduled' THEN
        SELECT capacity, status INTO venue_capacity, venue_status
          FROM gym_venues WHERE id = NEW.venue_id AND gym_id = NEW.gym_id FOR SHARE;

        IF TG_OP = 'INSERT' OR NEW.venue_id <> OLD.venue_id OR OLD.status <> 'scheduled' THEN
          IF venue_status <> 'active' THEN
            RAISE EXCEPTION 'classes are scheduled in active venues'
              USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_venue_active';
          END IF;
        END IF;

        IF venue_capacity IS NOT NULL AND NEW.capacity > venue_capacity THEN
          RAISE EXCEPTION 'the class capacity exceeds the venue capacity'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_class_occurrences_venue_capacity';
        END IF;
      END IF;

      reassigned := TG_OP = 'INSERT'
        OR NEW.instructor_staff_membership_id IS DISTINCT FROM OLD.instructor_staff_membership_id
        OR (OLD.status <> 'scheduled' AND NEW.status = 'scheduled');

      IF NEW.instructor_staff_membership_id IS NULL THEN
        NEW.instructor_user_id := NULL;
      ELSIF reassigned AND NEW.status = 'scheduled' THEN
        NEW.instructor_user_id := gym_class_instructor(NEW.gym_id, NEW.instructor_staff_membership_id);
      ELSIF TG_OP = 'UPDATE' THEN
        NEW.instructor_user_id := OLD.instructor_user_id;
      END IF;

      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER gym_class_occurrences_guard BEFORE INSERT OR UPDATE ON gym_class_occurrences
    FOR EACH ROW EXECUTE FUNCTION gym_class_occurrences_guard()
    """)

    # Rows are never deleted (history), except by the test-cleanup switch of
    # the SF-95 guard (`simple_fit.allow_gym_member_purge`) for its own
    # transaction.
    execute("""
    CREATE FUNCTION gym_schedule_guard_delete() RETURNS trigger AS $$
    BEGIN
      IF coalesce(current_setting('simple_fit.allow_gym_member_purge', true), '') <> 'on' THEN
        RAISE EXCEPTION 'gym scheduling records are never deleted'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'gym_schedule_no_delete';
      END IF;
      RETURN OLD;
    END
    $$ LANGUAGE plpgsql
    """)

    for table <- ~w(gym_venues gym_class_templates gym_class_series gym_class_occurrences) do
      execute("""
      CREATE TRIGGER #{table}_guard_delete BEFORE DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION gym_schedule_guard_delete()
      """)
    end

    # -- Audit -----------------------------------------------------------------------

    alter table(:gym_audit_events) do
      add :venue_id, :binary_id
      add :class_template_id, :binary_id
      add :class_series_id, :binary_id
      add :class_occurrence_id, :binary_id
      # How many occurrences a series change touched (no names, no times).
      add :occurrence_count, :integer
    end

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(event_types(:sf97))})"
           )
  end

  def down do
    execute("DELETE FROM gym_audit_events WHERE event_type IN (#{quoted(event_types(:new))})")

    drop constraint(:gym_audit_events, :event_type_values)

    create constraint(:gym_audit_events, :event_type_values,
             check: "event_type IN (#{quoted(event_types(:sf95))})"
           )

    alter table(:gym_audit_events) do
      remove :venue_id
      remove :class_template_id
      remove :class_series_id
      remove :class_occurrence_id
      remove :occurrence_count
    end

    for table <- ~w(gym_class_occurrences gym_class_series gym_class_templates gym_venues) do
      execute("DROP TRIGGER #{table}_guard_delete ON #{table}")
    end

    execute("DROP FUNCTION gym_schedule_guard_delete()")
    execute("DROP TRIGGER gym_class_occurrences_guard ON gym_class_occurrences")
    execute("DROP FUNCTION gym_class_occurrences_guard()")
    execute("DROP TRIGGER gym_class_series_guard ON gym_class_series")
    execute("DROP FUNCTION gym_class_series_guard()")
    execute("DROP TRIGGER gym_class_templates_guard ON gym_class_templates")
    execute("DROP FUNCTION gym_class_templates_guard()")
    execute("DROP TRIGGER gym_venues_guard ON gym_venues")
    execute("DROP FUNCTION gym_venues_guard()")

    drop table(:gym_class_occurrences)
    execute("DROP FUNCTION gym_class_instructor(uuid, uuid)")
    drop table(:gym_class_series)
    drop table(:gym_class_templates)
    drop table(:gym_venues)
    drop index(:gym_locations, [:gym_id, :id], name: :gym_locations_gym_id_id_index)

    execute("DROP FUNCTION scheduling_valid_weekdays(smallint[])")
    execute("DROP FUNCTION scheduling_resolve_local(timestamp, text)")
    execute("DROP FUNCTION scheduling_valid_time_zone(text)")
    # btree_gist stays: other objects of the database may rely on it.
  end

  @sf95 ~w(gym_created staff_membership_created ownership_transferred
           staff_membership_ended primary_location_set setup_completed draft_discarded
           first_run_completed first_run_dismissed staff_invited
           staff_invitation_cancelled staff_invitation_accepted
           staff_invitation_declined staff_role_changed
           member_join_requested member_join_approved member_join_auto_approved
           member_join_rejected member_join_cancelled member_ended
           member_invited member_invitation_cancelled member_invitation_accepted
           member_invitation_declined join_code_rotated join_code_disabled
           member_auto_approval_changed)

  @new ~w(venue_created venue_updated venue_deactivated
          class_template_created class_template_updated class_template_archived
          class_series_created class_series_updated class_series_cancelled
          class_occurrence_created class_occurrence_rescheduled class_occurrence_cancelled
          class_instructor_changed class_capacity_changed class_instructor_released)

  defp event_types(:sf95), do: @sf95
  defp event_types(:new), do: @new
  defp event_types(:sf97), do: @sf95 ++ @new

  defp quoted(types), do: Enum.map_join(types, ", ", &"'#{&1}'")
end
