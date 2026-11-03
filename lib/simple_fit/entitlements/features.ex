defmodule SimpleFit.Entitlements.Features do
  @moduledoc """
  The registry of SaaS feature keys a plan version may include (SF-101).
  A key names a commercial capability; which plan includes it is a product
  decision recorded on each published plan version, never inferred from a
  plan's name. No provisional plan includes any key (none is approved).

  `enforced` says whether any SimpleFit endpoint gates on the key. None does:
  every operational feature of SF-83 to SF-100 stays available to every gym
  until a commercial rollout and grandfathering policy are approved, so an
  entitlement projection never revokes existing access.
  """

  @features [
    {"gym.member_management", "Members, join requests and invitations"},
    {"gym.staff_management", "Staff roles and invitations"},
    {"gym.timetable", "Venues, class templates, series and classes"},
    {"gym.class_bookings", "Member class booking and rosters"},
    {"gym.additional_locations", "More than one location"},
    {"gym.advanced_analytics", "Analytics beyond the operational views"},
    {"gym.custom_branding", "Logo and colours on member surfaces"},
    {"gym.member_commerce", "Selling member products and passes"}
  ]

  @keys Enum.map(@features, &elem(&1, 0))

  @doc "Every registered feature key, in registry order."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "Whether `key` is a registered feature (an unknown key is always denied)."
  @spec known?(term()) :: boolean()
  def known?(key), do: key in @keys

  @doc "The registry: key and description."
  @spec all() :: [%{key: String.t(), description: String.t(), enforced: false}]
  def all,
    do: Enum.map(@features, fn {key, text} -> %{key: key, description: text, enforced: false} end)
end
