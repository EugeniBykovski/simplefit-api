defmodule SimpleFitWeb.Schemas.GymTimetableFields do
  @moduledoc """
  Shared OpenAPI definitions of the gym timetable (SF-97): venues, class
  templates, weekly series and class occurrences.
  """

  alias OpenApiSpex.Schema

  @doc "A UUID."
  def uuid(description), do: %Schema{type: :string, format: :uuid, description: description}

  @doc "A nullable UUID."
  def uuid_or_null(description),
    do: %Schema{type: :string, format: :uuid, nullable: true, description: description}

  @doc "A timestamp."
  def at(description), do: %Schema{type: :string, format: :"date-time", description: description}

  @doc "A nullable timestamp."
  def at_or_null(description),
    do: %Schema{type: :string, format: :"date-time", nullable: true, description: description}

  @doc "The idempotency key of a create."
  def client_request_id do
    %Schema{
      type: :string,
      format: :uuid,
      description: """
      A key the client generates once per intended creation. Sending the same key again (a retry after a lost
      answer) returns what it created with `200` instead of creating another.
      """
    }
  end

  @doc "The revision a change is based on."
  def expected_revision do
    %Schema{
      type: :integer,
      minimum: 1,
      description:
        "The `revision` the change is based on. Required; another one is a `409 conflict` (`details.revision: \"stale\"`, `details.current_revision`) and nothing changes."
    }
  end

  @doc "A revision."
  def revision,
    do: %Schema{
      type: :integer,
      minimum: 1,
      description: "Increases with every change of this record."
    }

  @doc "An IANA zone id."
  def time_zone do
    %Schema{
      type: :string,
      description:
        "An IANA zone id (`Europe/Warsaw`) or `UTC`, never a fixed offset or an abbreviation.",
      example: "Europe/Warsaw"
    }
  end

  @doc "A class duration."
  def duration(
        description \\ "Elapsed minutes (5–480): the class ends exactly this long after it starts."
      ),
      do: %Schema{type: :integer, minimum: 5, maximum: 480, description: description}

  @doc "A class capacity."
  def capacity(
        description \\ "The most participants (1–500). Not a booking count: nothing is booked here."
      ),
      do: %Schema{type: :integer, minimum: 1, maximum: 500, description: description}

  @doc "The instructor projection."
  def instructor do
    %Schema{
      type: :object,
      nullable: true,
      additionalProperties: false,
      required: [:staff_membership_id, :name],
      description:
        "The instructor: an active owner, manager or coach of the gym, as a short name (\"Tomasz Z.\"); never an email or profile. `null` without one.",
      properties: %{
        staff_membership_id: uuid("Their staff membership at this gym."),
        name: %Schema{type: :string, nullable: true, description: "First name and last initial."}
      }
    }
  end

  @doc "A venue reference."
  def venue_ref do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: [:venue_id, :name],
      properties: %{venue_id: uuid("The venue."), name: %Schema{type: :string}}
    }
  end

  @doc "ISO weekdays."
  def weekdays do
    %Schema{
      type: :array,
      minItems: 1,
      maxItems: 7,
      items: %Schema{type: :integer, minimum: 1, maximum: 7},
      description: "ISO weekdays: 1 = Monday … 7 = Sunday (sorted, no repeats).",
      example: [1, 3, 5]
    }
  end

  @doc "A wall-clock time."
  def local_time do
    %Schema{
      type: :string,
      pattern: "^([01][0-9]|2[0-3]):[0-5][0-9](:00)?$",
      description: "A wall-clock time in the venue's zone (`HH:MM`).",
      example: "18:00"
    }
  end

  @doc "A conflict description shared by the timetable writes."
  def conflicts do
    """
    * `conflict` - `details.schedule: "venue_unavailable"` (another scheduled class overlaps in the venue;
      `details.local_dates` names this gym's dates for a series) or `"instructor_unavailable"` (the instructor
      teaches another overlapping class, possibly at another gym: no details); a stale `expected_revision`
      (`details.revision: "stale"`); a draft gym (`details.setup_status: "draft"`).
    """
  end
end

defmodule SimpleFitWeb.Schemas.GymVenue do
  @moduledoc "OpenAPI schema: a gym venue (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymVenue",
      description: """
      A training area of the gym (room, ring, hall) at one of its locations. Every class takes place in one venue, and a venue holds one scheduled class at a time.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :venue_id,
        :gym_id,
        :gym_location_id,
        :name,
        :description,
        :capacity,
        :time_zone,
        :status,
        :revision,
        :created_at,
        :updated_at
      ],
      properties: %{
        venue_id: GymTimetableFields.uuid("The venue."),
        gym_id: GymTimetableFields.uuid("Its gym."),
        gym_location_id: GymTimetableFields.uuid("The gym location it is at."),
        name: %Schema{
          type: :string,
          description: "1–80 characters, unique among the gym's active venues."
        },
        description: %Schema{type: :string, nullable: true},
        capacity: %Schema{
          type: :integer,
          minimum: 1,
          maximum: 500,
          nullable: true,
          description: "The most people it holds; caps every class in it. `null`: no venue limit."
        },
        time_zone: GymTimetableFields.time_zone(),
        status: %Schema{
          type: :string,
          enum: ["active", "inactive"],
          description: "`inactive` takes no new classes and is final."
        },
        revision: GymTimetableFields.revision(),
        created_at: GymTimetableFields.at("When it was created."),
        updated_at: GymTimetableFields.at("When it last changed.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVenueList do
  @moduledoc "OpenAPI schema: a gym's venues (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymVenue

  OpenApiSpex.schema(
    %{
      title: "GymVenueList",
      type: :object,
      additionalProperties: false,
      required: [:venues],
      properties: %{venues: %Schema{type: :array, items: GymVenue, description: "By name."}}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVenueResponse do
  @moduledoc "OpenAPI schema: one gym venue (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymVenue

  OpenApiSpex.schema(
    %{
      title: "GymVenueResponse",
      type: :object,
      additionalProperties: false,
      required: [:venue],
      properties: %{venue: GymVenue}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVenueCreateRequest do
  @moduledoc "OpenAPI schema: create a gym venue (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymVenueCreateRequest",
      description: """
      Any other field is a `422 validation_error`. The zone never changes later.
      """,
      type: :object,
      required: [:client_request_id, :gym_location_id, :name, :time_zone],
      properties: %{
        client_request_id: GymTimetableFields.client_request_id(),
        gym_location_id: GymTimetableFields.uuid("An active location of this gym."),
        name: %Schema{type: :string, minLength: 1, maxLength: 80},
        description: %Schema{type: :string, nullable: true, maxLength: 500},
        capacity: %Schema{type: :integer, minimum: 1, maximum: 500, nullable: true},
        time_zone: GymTimetableFields.time_zone()
      },
      example: %{
        client_request_id: "0f8fad5b-d9cb-469f-a165-70867728950e",
        gym_location_id: "6a0f1c2e-1b2a-4c3d-9e8f-1a2b3c4d5e6f",
        name: "Ring 1",
        capacity: 20,
        time_zone: "Europe/Warsaw"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymVenueUpdateRequest do
  @moduledoc "OpenAPI schema: change a gym venue (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymVenueUpdateRequest",
      description: """
      Only the fields sent change; `null` clears `description` or `capacity`. Any other field is a `422`.
      """,
      type: :object,
      required: [:expected_revision],
      properties: %{
        expected_revision: GymTimetableFields.expected_revision(),
        gym_location_id: GymTimetableFields.uuid("An active location of this gym."),
        name: %Schema{type: :string, minLength: 1, maxLength: 80},
        description: %Schema{type: :string, nullable: true, maxLength: 500},
        capacity: %Schema{type: :integer, minimum: 1, maximum: 500, nullable: true}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymRevisionRequest do
  @moduledoc "OpenAPI schema: the revision an action is based on (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymRevisionRequest",
      type: :object,
      required: [:expected_revision],
      properties: %{expected_revision: GymTimetableFields.expected_revision()}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassTemplate do
  @moduledoc "OpenAPI schema: a gym class template (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassTemplate",
      description: """
      A reusable class definition. Not a scheduled class; editing it never changes classes already scheduled.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :template_id,
        :gym_id,
        :title,
        :description,
        :default_duration_minutes,
        :default_capacity,
        :default_venue_id,
        :default_instructor,
        :status,
        :revision,
        :created_at,
        :updated_at
      ],
      properties: %{
        template_id: GymTimetableFields.uuid("The template."),
        gym_id: GymTimetableFields.uuid("Its gym."),
        title: %Schema{type: :string, description: "1–80 characters."},
        description: %Schema{type: :string, nullable: true},
        default_duration_minutes: GymTimetableFields.duration("Default for new classes."),
        default_capacity: GymTimetableFields.capacity("Default for new classes."),
        default_venue_id: GymTimetableFields.uuid_or_null("Default venue for new classes."),
        default_instructor: GymTimetableFields.instructor(),
        status: %Schema{
          type: :string,
          enum: ["active", "archived"],
          description: "`archived` takes no new classes and is final."
        },
        revision: GymTimetableFields.revision(),
        created_at: GymTimetableFields.at("When it was created."),
        updated_at: GymTimetableFields.at("When it last changed.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassTemplateList do
  @moduledoc "OpenAPI schema: a gym's class templates (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymClassTemplate

  OpenApiSpex.schema(
    %{
      title: "GymClassTemplateList",
      type: :object,
      additionalProperties: false,
      required: [:templates],
      properties: %{
        templates: %Schema{type: :array, items: GymClassTemplate, description: "By title."}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassTemplateResponse do
  @moduledoc "OpenAPI schema: one class template (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymClassTemplate

  OpenApiSpex.schema(
    %{
      title: "GymClassTemplateResponse",
      type: :object,
      additionalProperties: false,
      required: [:template],
      properties: %{template: GymClassTemplate}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassTemplateCreateRequest do
  @moduledoc "OpenAPI schema: create a class template (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassTemplateCreateRequest",
      description: """
      Any other field is a `422 validation_error`.
      """,
      type: :object,
      required: [:client_request_id, :title, :default_duration_minutes, :default_capacity],
      properties: %{
        client_request_id: GymTimetableFields.client_request_id(),
        title: %Schema{type: :string, minLength: 1, maxLength: 80},
        description: %Schema{type: :string, nullable: true, maxLength: 1000},
        default_duration_minutes: GymTimetableFields.duration(),
        default_capacity: GymTimetableFields.capacity(),
        default_venue_id:
          GymTimetableFields.uuid_or_null(
            "An active venue of this gym that holds the default capacity."
          ),
        default_instructor_staff_membership_id:
          GymTimetableFields.uuid_or_null("An active owner, manager or coach of this gym.")
      },
      example: %{
        client_request_id: "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
        title: "Boxing Fundamentals",
        default_duration_minutes: 90,
        default_capacity: 16
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassTemplateUpdateRequest do
  @moduledoc "OpenAPI schema: change a class template (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassTemplateUpdateRequest",
      description: """
      Only the fields sent change; `null` clears an optional default. Scheduled classes are not changed.
      """,
      type: :object,
      required: [:expected_revision],
      properties: %{
        expected_revision: GymTimetableFields.expected_revision(),
        title: %Schema{type: :string, minLength: 1, maxLength: 80},
        description: %Schema{type: :string, nullable: true, maxLength: 1000},
        default_duration_minutes: GymTimetableFields.duration(),
        default_capacity: GymTimetableFields.capacity(),
        default_venue_id:
          GymTimetableFields.uuid_or_null(
            "An active venue of this gym that holds the default capacity."
          ),
        default_instructor_staff_membership_id:
          GymTimetableFields.uuid_or_null("An active owner, manager or coach of this gym.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassSeries do
  @moduledoc "OpenAPI schema: a weekly class series (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassSeries",
      description: """
      A bounded weekly rule in its venue's zone, fully materialized into class occurrences (one per date).
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :series_id,
        :gym_id,
        :template_id,
        :title,
        :venue,
        :instructor,
        :time_zone,
        :weekdays,
        :local_start_time,
        :duration_minutes,
        :capacity,
        :starts_on,
        :ends_on,
        :status,
        :revision,
        :created_at,
        :updated_at
      ],
      properties: %{
        series_id: GymTimetableFields.uuid("The series."),
        gym_id: GymTimetableFields.uuid("Its gym."),
        template_id: GymTimetableFields.uuid("Its class template."),
        title: %Schema{type: :string, description: "The template's title."},
        venue: GymTimetableFields.venue_ref(),
        instructor: GymTimetableFields.instructor(),
        time_zone: GymTimetableFields.time_zone(),
        weekdays: GymTimetableFields.weekdays(),
        local_start_time: GymTimetableFields.local_time(),
        duration_minutes: GymTimetableFields.duration(),
        capacity: GymTimetableFields.capacity(),
        starts_on: %Schema{
          type: :string,
          format: :date,
          description: "The first date (in the venue's zone)."
        },
        ends_on: %Schema{
          type: :string,
          format: :date,
          description: "The last date (at most a year after the first)."
        },
        status: %Schema{
          type: :string,
          enum: ["active", "cancelled"],
          description: "`cancelled` is final."
        },
        revision: GymTimetableFields.revision(),
        scheduled_count: %Schema{
          type: :integer,
          minimum: 0,
          description: "Its scheduled classes (past and future). Detail views only."
        },
        cancelled_count: %Schema{
          type: :integer,
          minimum: 0,
          description: "Its cancelled classes. Detail views only."
        },
        skipped_dates: %Schema{
          type: :array,
          description: """
          Dates of the rule on which the local start time does not exist (`nonexistent_local_time`, a spring-forward
          gap) or exists twice (`ambiguous_local_time`, an autumn repeated hour): no class is scheduled on them;
          schedule one as a one-time class with an explicit offset if wanted. Detail views only.
          """,
          items: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:local_date, :reason],
            properties: %{
              local_date: %Schema{type: :string, format: :date},
              reason: %Schema{
                type: :string,
                enum: ["nonexistent_local_time", "ambiguous_local_time"]
              }
            }
          }
        },
        created_at: GymTimetableFields.at("When it was created."),
        updated_at: GymTimetableFields.at("When it last changed.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassSeriesList do
  @moduledoc "OpenAPI schema: a gym's class series (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymClassSeries

  OpenApiSpex.schema(
    %{
      title: "GymClassSeriesList",
      type: :object,
      additionalProperties: false,
      required: [:series],
      properties: %{
        series: %Schema{type: :array, items: GymClassSeries, description: "Newest first."}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassSeriesResponse do
  @moduledoc "OpenAPI schema: one class series (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymClassSeries

  OpenApiSpex.schema(
    %{
      title: "GymClassSeriesResponse",
      type: :object,
      additionalProperties: false,
      required: [:series],
      properties: %{series: GymClassSeries}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassSeriesGenerateResponse do
  @moduledoc "OpenAPI schema: a series regeneration (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymClassSeries

  OpenApiSpex.schema(
    %{
      title: "GymClassSeriesGenerateResponse",
      type: :object,
      additionalProperties: false,
      required: [:series, :created_count],
      properties: %{
        series: GymClassSeries,
        created_count: %Schema{
          type: :integer,
          minimum: 0,
          description: "Classes created now (normally 0: a series is materialized when written)."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassSeriesCreateRequest do
  @moduledoc "OpenAPI schema: create a weekly class series (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassSeriesCreateRequest",
      description: """
      `venue_id`, `instructor_staff_membership_id`, `duration_minutes` and `capacity` default to the template's. Any other field is a `422`.
      """,
      type: :object,
      required: [
        :client_request_id,
        :template_id,
        :weekdays,
        :local_start_time,
        :starts_on,
        :ends_on
      ],
      properties: %{
        client_request_id: GymTimetableFields.client_request_id(),
        template_id: GymTimetableFields.uuid("An active class template of this gym."),
        starts_on: %Schema{
          type: :string,
          format: :date,
          description: "Today or later, in the venue's zone."
        },
        venue_id:
          GymTimetableFields.uuid("An active venue of this gym (on a change: in the same zone)."),
        instructor_staff_membership_id:
          GymTimetableFields.uuid_or_null(
            "An active owner, manager or coach of this gym; `null`: none."
          ),
        weekdays: GymTimetableFields.weekdays(),
        local_start_time: GymTimetableFields.local_time(),
        duration_minutes: GymTimetableFields.duration(),
        capacity: GymTimetableFields.capacity(),
        ends_on: %Schema{type: :string, format: :date}
      },
      example: %{
        client_request_id: "6fa459ea-ee8a-3ca4-894e-db77e160355e",
        template_id: "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
        weekdays: [1, 3, 5],
        local_start_time: "18:00",
        starts_on: "2026-11-02",
        ends_on: "2027-01-31"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassSeriesUpdateRequest do
  @moduledoc "OpenAPI schema: change a weekly class series (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassSeriesUpdateRequest",
      description: """
      Only the fields sent change. The template, zone and first date never change. Its classes still to come that were not changed or cancelled on their own are rewritten; see the operation.
      """,
      type: :object,
      required: [:expected_revision],
      properties: %{
        expected_revision: GymTimetableFields.expected_revision(),
        venue_id:
          GymTimetableFields.uuid("An active venue of this gym (on a change: in the same zone)."),
        instructor_staff_membership_id:
          GymTimetableFields.uuid_or_null(
            "An active owner, manager or coach of this gym; `null`: none."
          ),
        weekdays: GymTimetableFields.weekdays(),
        local_start_time: GymTimetableFields.local_time(),
        duration_minutes: GymTimetableFields.duration(),
        capacity: GymTimetableFields.capacity(),
        ends_on: %Schema{type: :string, format: :date}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassOccurrence do
  @moduledoc "OpenAPI schema: a scheduled gym class (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassOccurrence",
      description: """
      An actual dated class of the gym. Not a training session and never a booking; no participant counts exist.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :occurrence_id,
        :gym_id,
        :template_id,
        :series_id,
        :series_local_date,
        :title,
        :status,
        :starts_at,
        :ends_at,
        :time_zone,
        :local_starts_at,
        :local_ends_at,
        :utc_offset_minutes,
        :duration_minutes,
        :capacity,
        :venue,
        :instructor,
        :needs_instructor,
        :rescheduled,
        :cancelled_at,
        :cancel_reason,
        :revision,
        :created_at,
        :updated_at
      ],
      properties: %{
        occurrence_id: GymTimetableFields.uuid("The class."),
        gym_id: GymTimetableFields.uuid("Its gym."),
        template_id: GymTimetableFields.uuid("Its class template."),
        series_id: GymTimetableFields.uuid_or_null("Its series; `null` for a one-time class."),
        series_local_date: %Schema{
          type: :string,
          format: :date,
          nullable: true,
          description:
            "Its date in the series (its identity there, kept if it is moved); `null` for a one-time class."
        },
        title: %Schema{type: :string, description: "The title it was scheduled with."},
        status: %Schema{
          type: :string,
          enum: ["scheduled", "cancelled"],
          description: "Nothing is inferred from the clock: no completed or attendance state."
        },
        starts_at: GymTimetableFields.at("Start, UTC."),
        ends_at: GymTimetableFields.at("End, UTC: exactly `duration_minutes` after the start."),
        time_zone: GymTimetableFields.time_zone(),
        local_starts_at: %Schema{
          type: :string,
          description: "The wall-clock start in `time_zone` (`YYYY-MM-DDTHH:MM:SS`, no offset).",
          example: "2026-11-02T18:00:00"
        },
        local_ends_at: %Schema{type: :string, description: "The wall-clock end in `time_zone`."},
        utc_offset_minutes: %Schema{
          type: :integer,
          description:
            "The zone's offset at the start (it tells the two instants of a repeated hour apart)."
        },
        duration_minutes: GymTimetableFields.duration(),
        capacity: GymTimetableFields.capacity(),
        venue: GymTimetableFields.venue_ref(),
        instructor: GymTimetableFields.instructor(),
        needs_instructor: %Schema{
          type: :boolean,
          description:
            "Its instructor lost their staff access or eligibility and was taken off; assign another."
        },
        rescheduled: %Schema{
          type: :boolean,
          description:
            "A series class changed on its own: later series changes leave it as it is."
        },
        cancelled_at: GymTimetableFields.at_or_null("When it was cancelled."),
        cancel_reason: %Schema{
          type: :string,
          nullable: true,
          enum: ["cancelled", "series_changed", "series_cancelled", nil],
          description:
            "`cancelled` (by staff; final), `series_changed` (the series rule no longer has the date) or `series_cancelled`."
        },
        revision: GymTimetableFields.revision(),
        created_at: GymTimetableFields.at("When it was scheduled."),
        updated_at: GymTimetableFields.at("When it last changed.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassOccurrenceList do
  @moduledoc "OpenAPI schema: one page of a gym's classes (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymClassOccurrence, GymFields}

  OpenApiSpex.schema(
    %{
      title: "GymClassOccurrenceList",
      type: :object,
      additionalProperties: false,
      required: [:occurrences, :next_cursor],
      properties: %{
        occurrences: %Schema{
          type: :array,
          items: GymClassOccurrence,
          description: "By start time."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassOccurrenceResponse do
  @moduledoc "OpenAPI schema: one gym class (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymClassOccurrence

  OpenApiSpex.schema(
    %{
      title: "GymClassOccurrenceResponse",
      type: :object,
      additionalProperties: false,
      required: [:occurrence],
      properties: %{occurrence: GymClassOccurrence}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassOccurrenceCreateRequest do
  @moduledoc "OpenAPI schema: schedule a one-time gym class (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassOccurrenceCreateRequest",
      description: """
      `venue_id`, `instructor_staff_membership_id`, `duration_minutes` and `capacity` default to the template's. Any other field is a `422`.
      """,
      type: :object,
      required: [:client_request_id, :template_id, :starts_at],
      properties: %{
        client_request_id: GymTimetableFields.client_request_id(),
        template_id: GymTimetableFields.uuid("An active class template of this gym."),
        starts_at: %Schema{
          type: :string,
          format: :"date-time",
          description: """
          RFC 3339 with an explicit offset that is the venue zone's offset at that instant (or `Z`): a time in a
          spring-forward gap cannot be sent; the two instants of a repeated autumn hour are told apart by the
          offset. In the future, at most a year ahead.
          """,
          example: "2026-11-02T18:00:00+01:00"
        },
        venue_id: GymTimetableFields.uuid("An active venue of this gym."),
        instructor_staff_membership_id:
          GymTimetableFields.uuid_or_null(
            "An active owner, manager or coach of this gym; `null`: none."
          ),
        duration_minutes: GymTimetableFields.duration(),
        capacity: GymTimetableFields.capacity()
      },
      example: %{
        client_request_id: "a8098c1a-f86e-11da-bd1a-00112444be1e",
        template_id: "1b4e28ba-2fa1-11d2-883f-0016d3cca427",
        starts_at: "2026-11-07T10:00:00+01:00"
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassOccurrenceUpdateRequest do
  @moduledoc "OpenAPI schema: change one gym class (SF-97)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassOccurrenceUpdateRequest",
      description: """
      Only the fields sent change; `null` removes the instructor. Every rule and conflict is checked again.
      """,
      type: :object,
      required: [:expected_revision],
      properties: %{
        expected_revision: GymTimetableFields.expected_revision(),
        starts_at: %Schema{
          type: :string,
          format: :"date-time",
          description: """
          RFC 3339 with an explicit offset that is the venue zone's offset at that instant (or `Z`): a time in a
          spring-forward gap cannot be sent; the two instants of a repeated autumn hour are told apart by the
          offset. In the future, at most a year ahead.
          """,
          example: "2026-11-02T18:00:00+01:00"
        },
        venue_id: GymTimetableFields.uuid("An active venue of this gym in the same zone."),
        instructor_staff_membership_id:
          GymTimetableFields.uuid_or_null(
            "An active owner, manager or coach of this gym; `null`: none."
          ),
        duration_minutes: GymTimetableFields.duration(),
        capacity: GymTimetableFields.capacity()
      }
    },
    struct?: false
  )
end
