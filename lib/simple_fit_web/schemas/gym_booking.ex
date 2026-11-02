defmodule SimpleFitWeb.Schemas.GymBookingFields do
  @moduledoc """
  Shared OpenAPI definitions of gym class bookings and check-ins (SF-99).
  """

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  @doc "A booking status."
  def booking_status do
    %Schema{
      type: :string,
      enum: ["confirmed", "cancelled"],
      description: "`confirmed` holds a place; `cancelled` is history (final) and holds none."
    }
  end

  @doc "Why a booking was cancelled."
  def cancel_reason do
    %Schema{
      type: :string,
      nullable: true,
      enum: [
        "member_cancelled",
        "staff_cancelled",
        "occurrence_cancelled",
        "membership_ended",
        nil
      ],
      description:
        "`member_cancelled`, `staff_cancelled`, `occurrence_cancelled` (the class was cancelled) or `membership_ended` (the membership ended before the class)."
    }
  end

  @doc "Who made a booking."
  def booked_via do
    %Schema{
      type: :string,
      enum: ["member", "staff"],
      description: "The member themselves or a staff member for them."
    }
  end

  @doc "A short name, never more."
  def name do
    %Schema{
      type: :string,
      nullable: true,
      description: "First name and last initial (\"Marta K.\"); `null` without one."
    }
  end

  @doc "The wall-clock and zone fields of a class."
  def class_time_properties do
    %{
      starts_at: GymTimetableFields.at("Start, UTC."),
      ends_at: GymTimetableFields.at("End, UTC."),
      time_zone: GymTimetableFields.time_zone(),
      local_starts_at: %Schema{
        type: :string,
        description: "The wall-clock start in `time_zone` (`YYYY-MM-DDTHH:MM:SS`, no offset)."
      },
      local_ends_at: %Schema{type: :string, description: "The wall-clock end in `time_zone`."},
      utc_offset_minutes: %Schema{type: :integer, description: "The zone's offset at the start."}
    }
  end

  @doc "A name-only reference (venue, instructor)."
  def named(description, nullable \\ false) do
    %Schema{
      type: :object,
      nullable: nullable,
      additionalProperties: false,
      required: [:name],
      properties: %{name: %Schema{type: :string, nullable: true}},
      description: description
    }
  end

  @doc "The access errors of the member side."
  def member_access do
    """
    * `not_found` - not one of the viewer's own memberships (or bookings), or an unknown or another gym's class.
    * `conflict` - `details.gym_member` is the membership's status when it is not `active` (a request, an ended,
      rejected or cancelled membership books nothing).
    """
  end

  @doc "The booking conflicts."
  def conflicts do
    """
    * `conflict` - `details.class_occurrence: "full"` (no place left; `details.capacity`), `"cancelled"` or
      `"started"`; `details.class_booking: "already_booked"` (a confirmed booking of this class exists for the
      member); `details.client_request_id: "reused"` (the key named another booking); a draft gym
      (`details.setup_status`).
    """
  end
end

defmodule SimpleFitWeb.Schemas.GymMemberClass do
  @moduledoc "OpenAPI schema: a class as a member of its gym sees it (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymBookingFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymMemberClass",
      description:
        "One class of the gym with the places left and the viewer's own booking. Never another participant.",
      type: :object,
      additionalProperties: false,
      required: [
        :occurrence_id,
        :title,
        :status,
        :starts_at,
        :ends_at,
        :time_zone,
        :local_starts_at,
        :local_ends_at,
        :utc_offset_minutes,
        :duration_minutes,
        :venue,
        :instructor,
        :capacity,
        :remaining_capacity,
        :booking
      ],
      properties:
        Map.merge(GymBookingFields.class_time_properties(), %{
          occurrence_id: GymTimetableFields.uuid("The class."),
          title: %Schema{type: :string},
          status: %Schema{
            type: :string,
            enum: ["scheduled", "cancelled"],
            description: "A cancelled class takes no booking."
          },
          duration_minutes: GymTimetableFields.duration(),
          venue: GymBookingFields.named("The venue."),
          instructor: GymBookingFields.named("The instructor; `null` without one.", true),
          capacity: GymTimetableFields.capacity("The most participants."),
          remaining_capacity: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "Places left (capacity minus confirmed bookings); `0` for a cancelled class."
          },
          booking: %Schema{
            type: :object,
            nullable: true,
            additionalProperties: false,
            required: [:booking_id, :status, :checked_in_at],
            properties: %{
              booking_id: GymTimetableFields.uuid("The viewer's booking."),
              status: GymBookingFields.booking_status(),
              checked_in_at:
                GymTimetableFields.at_or_null("When staff recorded the viewer's arrival.")
            },
            description:
              "The viewer's booking of this class (the confirmed one, else the latest); `null`."
          }
        })
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymMemberClassList do
  @moduledoc "OpenAPI schema: one page of a gym's classes for its member (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, GymMemberClass}

  OpenApiSpex.schema(
    %{
      title: "GymMemberClassList",
      type: :object,
      additionalProperties: false,
      required: [:classes, :next_cursor],
      properties: %{
        classes: %Schema{type: :array, items: GymMemberClass, description: "By start time."},
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassAvailability do
  @moduledoc "OpenAPI schema: the places of a class (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassAvailability",
      description: "Counted from the confirmed bookings when the answer was made.",
      type: :object,
      additionalProperties: false,
      required: [:capacity, :confirmed_count, :remaining_capacity],
      properties: %{
        capacity: GymTimetableFields.capacity("The most participants."),
        confirmed_count: %Schema{type: :integer, minimum: 0},
        remaining_capacity: %Schema{type: :integer, minimum: 0}
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymClassBooking do
  @moduledoc "OpenAPI schema: one of the viewer's own class bookings (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymBookingFields, GymClassAvailability, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "MyGymClassBooking",
      description:
        "A place the viewer holds (or held) in a gym class. No price, payment or entitlement exists.",
      type: :object,
      additionalProperties: false,
      required: [
        :booking_id,
        :gym_member_id,
        :status,
        :booked_via,
        :confirmed_at,
        :cancelled_at,
        :cancel_reason,
        :checked_in_at,
        :class
      ],
      properties: %{
        booking_id: GymTimetableFields.uuid("The booking."),
        gym_member_id: GymTimetableFields.uuid("The viewer's membership it belongs to."),
        status: GymBookingFields.booking_status(),
        booked_via: GymBookingFields.booked_via(),
        confirmed_at: GymTimetableFields.at("When it was confirmed."),
        cancelled_at: GymTimetableFields.at_or_null("When it was cancelled."),
        cancel_reason: GymBookingFields.cancel_reason(),
        checked_in_at: GymTimetableFields.at_or_null("When staff recorded the viewer's arrival."),
        class: %Schema{
          type: :object,
          additionalProperties: false,
          required: [
            :occurrence_id,
            :gym,
            :title,
            :status,
            :starts_at,
            :ends_at,
            :time_zone,
            :local_starts_at,
            :local_ends_at,
            :utc_offset_minutes,
            :venue,
            :instructor
          ],
          properties:
            Map.merge(GymBookingFields.class_time_properties(), %{
              occurrence_id: GymTimetableFields.uuid("The class."),
              gym: %Schema{
                type: :object,
                additionalProperties: false,
                required: [:gym_id, :name],
                properties: %{
                  gym_id: GymTimetableFields.uuid("The gym."),
                  name: %Schema{type: :string, nullable: true}
                }
              },
              title: %Schema{type: :string},
              status: %Schema{type: :string, enum: ["scheduled", "cancelled"]},
              venue: GymBookingFields.named("The venue."),
              instructor: GymBookingFields.named("The instructor; `null` without one.", true)
            })
        },
        availability: GymClassAvailability
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymClassBookingList do
  @moduledoc "OpenAPI schema: one page of the viewer's class bookings (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymFields, MyGymClassBooking}

  OpenApiSpex.schema(
    %{
      title: "MyGymClassBookingList",
      type: :object,
      additionalProperties: false,
      required: [:bookings, :next_cursor],
      properties: %{
        bookings: %Schema{type: :array, items: MyGymClassBooking, description: "Newest first."},
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.MyGymClassBookingResponse do
  @moduledoc "OpenAPI schema: one of the viewer's class bookings (SF-99)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.MyGymClassBooking

  OpenApiSpex.schema(
    %{
      title: "MyGymClassBookingResponse",
      type: :object,
      additionalProperties: false,
      required: [:booking],
      properties: %{booking: MyGymClassBooking}
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassBookingRequest do
  @moduledoc "OpenAPI schema: book a place in a class (SF-99)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassBookingRequest",
      description: "Any other field is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:occurrence_id, :client_request_id],
      properties: %{
        occurrence_id: GymTimetableFields.uuid("A class of this membership's gym."),
        client_request_id: GymTimetableFields.client_request_id()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassBookingForMemberRequest do
  @moduledoc "OpenAPI schema: book a place for a member (SF-99)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassBookingForMemberRequest",
      description: "Any other field is a `422`.",
      type: :object,
      additionalProperties: false,
      required: [:gym_member_id, :client_request_id],
      properties: %{
        gym_member_id: GymTimetableFields.uuid("An active member of this gym."),
        client_request_id: GymTimetableFields.client_request_id()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassRosterSummary do
  @moduledoc "OpenAPI schema: the counts of a class roster (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassRosterSummary",
      description: "Counted from the booking and check-in rows when the answer was made.",
      type: :object,
      additionalProperties: false,
      required: [:capacity, :confirmed_count, :remaining_capacity, :checked_in_count],
      properties: %{
        capacity: GymTimetableFields.capacity("The most participants."),
        confirmed_count: %Schema{type: :integer, minimum: 0},
        remaining_capacity: %Schema{type: :integer, minimum: 0},
        checked_in_count: %Schema{
          type: :integer,
          minimum: 0,
          description: "Confirmed bookings with a recorded check-in."
        }
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassRosterEntry do
  @moduledoc "OpenAPI schema: one booking of a class roster (SF-99)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{GymBookingFields, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymClassRosterEntry",
      description:
        "What the gym's staff see of a booking: a short name and booking facts. Never an email, user id, profile, other gym or training data.",
      type: :object,
      additionalProperties: false,
      required: [
        :booking_id,
        :gym_member_id,
        :name,
        :status,
        :booked_via,
        :confirmed_at,
        :cancelled_at,
        :cancel_reason,
        :checked_in_at
      ],
      properties: %{
        booking_id: GymTimetableFields.uuid("The booking."),
        gym_member_id: GymTimetableFields.uuid("The member of this gym."),
        name: GymBookingFields.name(),
        status: GymBookingFields.booking_status(),
        booked_via: GymBookingFields.booked_via(),
        confirmed_at: GymTimetableFields.at("When it was confirmed."),
        cancelled_at: GymTimetableFields.at_or_null("When it was cancelled."),
        cancel_reason: GymBookingFields.cancel_reason(),
        checked_in_at: GymTimetableFields.at_or_null("When staff recorded the arrival.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassRoster do
  @moduledoc "OpenAPI schema: one page of a class roster (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.{GymClassRosterEntry, GymClassRosterSummary, GymFields}

  OpenApiSpex.schema(
    %{
      title: "GymClassRoster",
      type: :object,
      additionalProperties: false,
      required: [:summary, :bookings, :next_cursor],
      properties: %{
        summary: GymClassRosterSummary,
        bookings: %Schema{
          type: :array,
          items: GymClassRosterEntry,
          description: "Oldest confirmation first."
        },
        next_cursor: GymFields.next_cursor()
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassBookingResponse do
  @moduledoc "OpenAPI schema: a booking as the gym's staff see it (SF-99)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.{GymClassRosterEntry, GymClassRosterSummary, GymTimetableFields}

  OpenApiSpex.schema(
    %{
      title: "GymClassBookingResponse",
      type: :object,
      additionalProperties: false,
      required: [:booking, :occurrence_id, :summary],
      properties: %{
        booking: GymClassRosterEntry,
        occurrence_id: GymTimetableFields.uuid("The class."),
        summary: GymClassRosterSummary
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassCheckIn do
  @moduledoc "OpenAPI schema: a recorded class check-in (SF-99)."

  require OpenApiSpex

  alias OpenApiSpex.Schema
  alias SimpleFitWeb.Schemas.GymTimetableFields

  OpenApiSpex.schema(
    %{
      title: "GymClassCheckIn",
      description:
        "Staff recorded that the member of a confirmed booking came. Participation only: no result, note or training data.",
      type: :object,
      additionalProperties: false,
      required: [
        :check_in_id,
        :booking_id,
        :occurrence_id,
        :gym_member_id,
        :method,
        :checked_in_at
      ],
      properties: %{
        check_in_id: GymTimetableFields.uuid("The check-in."),
        booking_id: GymTimetableFields.uuid("The booking."),
        occurrence_id: GymTimetableFields.uuid("The class."),
        gym_member_id: GymTimetableFields.uuid("The member of this gym."),
        method: %Schema{
          type: :string,
          enum: ["manual"],
          description: "Recorded by hand (no pass scan exists)."
        },
        checked_in_at: GymTimetableFields.at("When it was recorded.")
      }
    },
    struct?: false
  )
end

defmodule SimpleFitWeb.Schemas.GymClassCheckInResponse do
  @moduledoc "OpenAPI schema: one class check-in (SF-99)."

  require OpenApiSpex

  alias SimpleFitWeb.Schemas.GymClassCheckIn

  OpenApiSpex.schema(
    %{
      title: "GymClassCheckInResponse",
      type: :object,
      additionalProperties: false,
      required: [:check_in],
      properties: %{check_in: GymClassCheckIn}
    },
    struct?: false
  )
end
