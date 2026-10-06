defmodule SimpleFitWeb.EmailAuthJSON do
  @moduledoc """
  JSON rendering of email authentication responses (ADR 0012). Session
  credentials are rendered by `SimpleFitWeb.SessionJSON`.
  """

  @spec registration_accepted(%{result: map()}) :: map()
  def registration_accepted(%{result: result}) do
    Map.take(result, [:registration_token, :expires_in_seconds, :resend_after_seconds])
  end

  @spec sign_in_accepted(%{result: map()}) :: map()
  def sign_in_accepted(%{result: result}) do
    Map.take(result, [:expires_in_seconds, :resend_after_seconds])
  end

  @spec registration_status(%{status: atom()}) :: map()
  def registration_status(%{status: status}), do: %{status: Atom.to_string(status)}

  @spec link_result(%{status: atom()}) :: map()
  def link_result(%{status: status}), do: %{status: Atom.to_string(status)}
end
