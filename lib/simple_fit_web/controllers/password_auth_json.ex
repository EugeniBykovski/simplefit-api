defmodule SimpleFitWeb.PasswordAuthJSON do
  @moduledoc """
  JSON rendering of password responses (SF-157). Session credentials are rendered by
  `SimpleFitWeb.SessionJSON`; nothing derived from a password is ever rendered.
  """

  @spec reset_accepted(%{result: map()}) :: map()
  def reset_accepted(%{result: result}),
    do: Map.take(result, [:expires_in_seconds, :resend_after_seconds])

  @spec status(%{password_set: boolean()}) :: map()
  def status(%{password_set: password_set}), do: %{password_set: password_set}
end
