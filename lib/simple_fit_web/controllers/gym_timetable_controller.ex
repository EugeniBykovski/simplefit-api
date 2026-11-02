defmodule SimpleFitWeb.GymTimetableController do
  @moduledoc """
  A gym's timetable (SF-97; ADR 0026 D-G14, D-G15): venues, class templates,
  weekly series and class occurrences. Every action acts for the session's
  own user on the gym named in the path; the rules live in `SimpleFit.Gyms`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Parameter, Schema}
  alias SimpleFit.Gyms
  alias SimpleFitWeb.{ApiSpec, Schemas}
  alias SimpleFitWeb.Schemas.GymTimetableFields

  action_fallback SimpleFitWeb.FallbackController

  plug :put_view, json: SimpleFitWeb.GymTimetableJSON

  tags ["Gym timetable"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  @gym_id %Parameter{
    name: :gym_id,
    in: :path,
    required: true,
    description: "The gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @venue_id %Parameter{
    name: :venue_id,
    in: :path,
    required: true,
    description: "A venue of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @template_id %Parameter{
    name: :template_id,
    in: :path,
    required: true,
    description: "A class template of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @series_id %Parameter{
    name: :series_id,
    in: :path,
    required: true,
    description: "A class series of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @occurrence_id %Parameter{
    name: :occurrence_id,
    in: :path,
    required: true,
    description: "A class of this gym.",
    schema: %Schema{type: :string, format: :uuid}
  }

  @limit %Parameter{
    name: :limit,
    in: :query,
    required: false,
    description: "Page size (1–100, default 50).",
    schema: %Schema{type: :integer, minimum: 1, maximum: 100}
  }
  @cursor %Parameter{
    name: :cursor,
    in: :query,
    required: false,
    description: "`next_cursor` of the previous page (same filters).",
    schema: %Schema{type: :string}
  }
  @from %Parameter{
    name: :from,
    in: :query,
    required: true,
    description: "Window start: an RFC 3339 instant with an offset.",
    schema: %Schema{type: :string, format: :"date-time"}
  }
  @to %Parameter{
    name: :to,
    in: :query,
    required: true,
    description: "Window end (exclusive), at most 31 days after `from`.",
    schema: %Schema{type: :string, format: :"date-time"}
  }
  @venue_filter %Parameter{
    name: :venue_id,
    in: :query,
    required: false,
    description: "Only this venue's classes.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @instructor_filter %Parameter{
    name: :instructor_staff_membership_id,
    in: :query,
    required: false,
    description: "Only this instructor's classes.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @template_filter %Parameter{
    name: :template_id,
    in: :query,
    required: false,
    description: "Only this template's classes.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @series_filter %Parameter{
    name: :series_id,
    in: :query,
    required: false,
    description: "Only this series' classes.",
    schema: %Schema{type: :string, format: :uuid}
  }
  @status_scheduled_cancelled %Parameter{
    name: :status,
    in: :query,
    required: false,
    description: "Only `scheduled` or `cancelled` classes (default: both).",
    schema: %Schema{type: :string, enum: ["scheduled", "cancelled"]}
  }
  @status_active_inactive %Parameter{
    name: :status,
    in: :query,
    required: false,
    description: "`active` (default) or `inactive`.",
    schema: %Schema{type: :string, enum: ["active", "inactive"]}
  }
  @status_active_archived %Parameter{
    name: :status,
    in: :query,
    required: false,
    description: "`active` (default) or `archived`.",
    schema: %Schema{type: :string, enum: ["active", "archived"]}
  }
  @status_active_cancelled %Parameter{
    name: :status,
    in: :query,
    required: false,
    description: "`active` (default) or `cancelled`.",
    schema: %Schema{type: :string, enum: ["active", "cancelled"]}
  }

  @access """
  * `not_found` - no such gym, or the viewer holds no active staff membership there (existence is never
    revealed); for a venue, template, series or class, also an unknown id or another gym's.
  """

  operation :venues,
    operation_id: "listGymVenues",
    summary: "A gym's venues",
    description: """
    The gym's active (default) or inactive venues, by name. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @status_active_inactive, @limit],
    responses: [
      ok: {"A gym's venues", "application/json", Schemas.GymVenueList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def venues(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_venues(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:venues, page: page)
    end
  end

  operation :create_venue,
    operation_id: "createGymVenue",
    summary: "Create a venue",
    description: """
    Creates a training area at one of the gym's active locations, with its IANA zone (fixed) and an optional capacity. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"Create a venue", "application/json", Schemas.GymVenueCreateRequest, required: true},
    responses: [
      created: {"Created", "application/json", Schemas.GymVenueResponse},
      ok:
        {"The one this `client_request_id` already created", "application/json",
         Schemas.GymVenueResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create_venue(conn, %{"gym_id" => gym_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.create_venue(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:venue, venue: view)
    end
  end

  operation :venue,
    operation_id: "getGymVenue",
    summary: "One venue",
    description: """
    One venue of the gym. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @venue_id],
    responses: [
      ok: {"One venue", "application/json", Schemas.GymVenueResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def venue(conn, %{"gym_id" => gym_id, "venue_id" => id}) do
    with {:ok, view} <- Gyms.get_venue(conn.assigns.current_user, gym_id, id) do
      conn |> no_store() |> render(:venue, venue: view)
    end
  end

  operation :update_venue,
    operation_id: "updateGymVenue",
    summary: "Change a venue",
    description: """
    Changes a venue's name, description, capacity or location. A capacity below a class still to come in it is a `409` (`details.venue: "capacity_below_upcoming_class"`). An inactive venue is a `409` (`details.venue: "inactive"`). Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @venue_id],
    request_body:
      {"Change a venue", "application/json", Schemas.GymVenueUpdateRequest, required: true},
    responses: [
      ok: {"Change a venue", "application/json", Schemas.GymVenueResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update_venue(conn, %{"gym_id" => gym_id, "venue_id" => id}) do
    with {:ok, view} <-
           Gyms.update_venue(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:venue, venue: view)
    end
  end

  operation :deactivate_venue,
    operation_id: "deactivateGymVenue",
    summary: "Deactivate a venue",
    description: """
    Deactivates a venue (final): it takes no new classes. Refused while classes are still to come in it (`409`, `details.venue: "has_upcoming_classes"`). Repeating it returns it unchanged. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @venue_id],
    request_body:
      {"Deactivate a venue", "application/json", Schemas.GymRevisionRequest, required: true},
    responses: [
      ok: {"Deactivate a venue", "application/json", Schemas.GymVenueResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def deactivate_venue(conn, %{"gym_id" => gym_id, "venue_id" => id}) do
    with {:ok, view} <-
           Gyms.deactivate_venue(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:venue, venue: view)
    end
  end

  operation :templates,
    operation_id: "listGymClassTemplates",
    summary: "A gym's class templates",
    description: """
    The gym's active (default) or archived class templates, by title. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @status_active_archived, @limit],
    responses: [
      ok: {"A gym's class templates", "application/json", Schemas.GymClassTemplateList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def templates(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_class_templates(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:templates, page: page)
    end
  end

  operation :create_template,
    operation_id: "createGymClassTemplate",
    summary: "Create a class template",
    description: """
    Creates a reusable class definition with defaults for new classes. Not a scheduled class (it does not complete `add_class`). Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"Create a class template", "application/json", Schemas.GymClassTemplateCreateRequest,
       required: true},
    responses: [
      created: {"Created", "application/json", Schemas.GymClassTemplateResponse},
      ok:
        {"The one this `client_request_id` already created", "application/json",
         Schemas.GymClassTemplateResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create_template(conn, %{"gym_id" => gym_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.create_class_template(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:template, template: view)
    end
  end

  operation :template,
    operation_id: "getGymClassTemplate",
    summary: "One class template",
    description: """
    One class template of the gym. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @template_id],
    responses: [
      ok: {"One class template", "application/json", Schemas.GymClassTemplateResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def template(conn, %{"gym_id" => gym_id, "template_id" => id}) do
    with {:ok, view} <- Gyms.get_class_template(conn.assigns.current_user, gym_id, id) do
      conn |> no_store() |> render(:template, template: view)
    end
  end

  operation :update_template,
    operation_id: "updateGymClassTemplate",
    summary: "Change a class template",
    description: """
    Changes a template's title, description and defaults. Classes already scheduled keep what they were scheduled with. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @template_id],
    request_body:
      {"Change a class template", "application/json", Schemas.GymClassTemplateUpdateRequest,
       required: true},
    responses: [
      ok: {"Change a class template", "application/json", Schemas.GymClassTemplateResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update_template(conn, %{"gym_id" => gym_id, "template_id" => id}) do
    with {:ok, view} <-
           Gyms.update_class_template(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:template, template: view)
    end
  end

  operation :archive_template,
    operation_id: "archiveGymClassTemplate",
    summary: "Archive a class template",
    description: """
    Archives a template (final): no new classes from it; its scheduled classes stay. Repeating it returns it unchanged. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @template_id],
    request_body:
      {"Archive a class template", "application/json", Schemas.GymRevisionRequest, required: true},
    responses: [
      ok: {"Archive a class template", "application/json", Schemas.GymClassTemplateResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def archive_template(conn, %{"gym_id" => gym_id, "template_id" => id}) do
    with {:ok, view} <-
           Gyms.archive_class_template(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:template, template: view)
    end
  end

  operation :series_index,
    operation_id: "listGymClassSeries",
    summary: "A gym's class series",
    description: """
    The gym's active (default) or cancelled weekly series, newest first. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @status_active_cancelled, @limit],
    responses: [
      ok: {"A gym's class series", "application/json", Schemas.GymClassSeriesList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def series_index(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_class_series(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:series_index, page: page)
    end
  end

  operation :create_series,
    operation_id: "createGymClassSeries",
    summary: "Create a weekly class series",
    description: """
    Creates a bounded weekly rule (weekdays, a wall-clock start time in the venue's zone, first and last dates at
    most a year apart) and schedules all its classes still to come at once, each checked against the venue and the
    instructor. Dates whose local start time does not exist (spring-forward gap) or exists twice (autumn repeated
    hour) are skipped and listed in `skipped_dates`, never shifted. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"Create a weekly class series", "application/json", Schemas.GymClassSeriesCreateRequest,
       required: true},
    responses: [
      created: {"Created", "application/json", Schemas.GymClassSeriesResponse},
      ok:
        {"The one this `client_request_id` already created", "application/json",
         Schemas.GymClassSeriesResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create_series(conn, %{"gym_id" => gym_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.create_class_series(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:series, series: view)
    end
  end

  operation :series,
    operation_id: "getGymClassSeries",
    summary: "One class series",
    description: """
    One series of the gym, with its class counts and skipped dates. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @series_id],
    responses: [
      ok: {"One class series", "application/json", Schemas.GymClassSeriesResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def series(conn, %{"gym_id" => gym_id, "series_id" => id}) do
    with {:ok, view} <- Gyms.get_class_series(conn.assigns.current_user, gym_id, id) do
      conn |> no_store() |> render(:series, series: view)
    end
  end

  operation :update_series,
    operation_id: "updateGymClassSeries",
    summary: "Change a weekly class series",
    description: """
    Changes a series and rewrites its classes still to come that were not changed or cancelled on their own: a
    date the rule keeps is updated, a date it loses is cancelled (`series_changed`), a new date is scheduled. Started
    classes, classes changed on their own and classes cancelled by staff stay as they are. The whole change is
    refused if any rewritten class would conflict. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @series_id],
    request_body:
      {"Change a weekly class series", "application/json", Schemas.GymClassSeriesUpdateRequest,
       required: true},
    responses: [
      ok: {"Change a weekly class series", "application/json", Schemas.GymClassSeriesResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update_series(conn, %{"gym_id" => gym_id, "series_id" => id}) do
    with {:ok, view} <-
           Gyms.update_class_series(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:series, series: view)
    end
  end

  operation :cancel_series,
    operation_id: "cancelGymClassSeries",
    summary: "Cancel a weekly class series",
    description: """
    Cancels a series (final) and all its classes still to come (`series_cancelled`); past classes stay. Repeating it returns it unchanged. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @series_id],
    request_body:
      {"Cancel a weekly class series", "application/json", Schemas.GymRevisionRequest,
       required: true},
    responses: [
      ok: {"Cancel a weekly class series", "application/json", Schemas.GymClassSeriesResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel_series(conn, %{"gym_id" => gym_id, "series_id" => id}) do
    with {:ok, view} <-
           Gyms.cancel_class_series(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:series, series: view)
    end
  end

  operation :generate_series,
    operation_id: "generateGymClassSeries",
    summary: "Schedule a series' missing dates",
    description: """
    Schedules any date of an active series' rule that has no class yet (normally none). Idempotent: never duplicates a date and never brings back a cancelled class. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @series_id],
    responses: [
      ok:
        {"The series and how many classes were created", "application/json",
         Schemas.GymClassSeriesGenerateResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def generate_series(conn, %{"gym_id" => gym_id, "series_id" => id}) do
    with {:ok, {view, created}} <-
           Gyms.generate_class_series(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id
           ) do
      conn |> no_store() |> render(:generate, series: view, created: created)
    end
  end

  operation :occurrences,
    operation_id: "listGymClassOccurrences",
    summary: "A gym's timetable",
    description: """
    The gym's classes starting in `[from, to)` (at most 31 days), by start time, with UTC instants, the zone and wall-clock times. No booking or attendance counts exist. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [
      @gym_id,
      @from,
      @to,
      @status_scheduled_cancelled,
      @venue_filter,
      @instructor_filter,
      @template_filter,
      @series_filter,
      @limit,
      @cursor
    ],
    responses: [
      ok: {"A gym's timetable", "application/json", Schemas.GymClassOccurrenceList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def occurrences(conn, %{"gym_id" => gym_id} = params) do
    with {:ok, page} <- Gyms.list_class_occurrences(conn.assigns.current_user, gym_id, params) do
      conn |> no_store() |> render(:occurrences, page: page)
    end
  end

  operation :create_occurrence,
    operation_id: "createGymClassOccurrence",
    summary: "Schedule a one-time class",
    description: """
    Schedules one class at an explicit instant (its offset must be the venue zone's at that instant). Creates no training session, membership, booking or attendance. Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id],
    request_body:
      {"Schedule a one-time class", "application/json", Schemas.GymClassOccurrenceCreateRequest,
       required: true},
    responses: [
      created: {"Created", "application/json", Schemas.GymClassOccurrenceResponse},
      ok:
        {"The one this `client_request_id` already created", "application/json",
         Schemas.GymClassOccurrenceResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def create_occurrence(conn, %{"gym_id" => gym_id}) do
    with {:ok, {view, outcome}} <-
           Gyms.create_class_occurrence(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             conn.body_params
           ) do
      conn
      |> no_store()
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:occurrence, occurrence: view)
    end
  end

  operation :occurrence,
    operation_id: "getGymClassOccurrence",
    summary: "One class",
    description: """
    One class of the gym. Any active staff member of the gym (owner, manager, coach, front desk).

    #{@access}
    * `validation_error` - an invalid filter, `limit` or `cursor`.
    """,
    security: @security,
    parameters: [@gym_id, @occurrence_id],
    responses: [
      ok: {"One class", "application/json", Schemas.GymClassOccurrenceResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      not_found: ApiSpec.error_response("not_found"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def occurrence(conn, %{"gym_id" => gym_id, "occurrence_id" => id}) do
    with {:ok, view} <- Gyms.get_class_occurrence(conn.assigns.current_user, gym_id, id) do
      conn |> no_store() |> render(:occurrence, occurrence: view)
    end
  end

  operation :update_occurrence,
    operation_id: "updateGymClassOccurrence",
    summary: "Change one class",
    description: """
    Reschedules one class still to come (time, duration, venue in the same zone, instructor, capacity); every rule and conflict is checked again. A series class changed this way is an exception (`rescheduled`): later series changes leave it. A cancelled or started class is a `409` (`details.class_occurrence`). Owner and managers (`manage_timetable`).

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @occurrence_id],
    request_body:
      {"Change one class", "application/json", Schemas.GymClassOccurrenceUpdateRequest,
       required: true},
    responses: [
      ok: {"Change one class", "application/json", Schemas.GymClassOccurrenceResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def update_occurrence(conn, %{"gym_id" => gym_id, "occurrence_id" => id}) do
    with {:ok, view} <-
           Gyms.update_class_occurrence(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:occurrence, occurrence: view)
    end
  end

  operation :cancel_occurrence,
    operation_id: "cancelGymClassOccurrence",
    summary: "Cancel one class",
    description: """
    Cancels one class still to come (final): it stays as a cancelled record and frees its venue and instructor. Owner and managers any class; a coach only a class they instruct (`cancel_occurrence`). A started class is a `409`. Repeating it returns it unchanged.

    #{@access}
    * `forbidden` - the viewer's role may not do this.
    #{GymTimetableFields.conflicts()}
    * `validation_error` - an invalid or unknown field.
    * `rate_limited` - 120 timetable changes per 10 minutes per user.
    """,
    security: @security,
    parameters: [@gym_id, @occurrence_id],
    request_body:
      {"Cancel one class", "application/json", Schemas.GymRevisionRequest, required: true},
    responses: [
      ok: {"Cancel one class", "application/json", Schemas.GymClassOccurrenceResponse},
      unauthorized: ApiSpec.error_response("unauthorized"),
      forbidden: ApiSpec.error_response("forbidden"),
      not_found: ApiSpec.error_response("not_found"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def cancel_occurrence(conn, %{"gym_id" => gym_id, "occurrence_id" => id}) do
    with {:ok, view} <-
           Gyms.cancel_class_occurrence(
             conn.assigns.current_user,
             conn.assigns.current_session,
             gym_id,
             id,
             conn.body_params
           ) do
      conn |> no_store() |> render(:occurrence, occurrence: view)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
