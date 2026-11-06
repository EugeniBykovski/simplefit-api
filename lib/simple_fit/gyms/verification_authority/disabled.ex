defmodule SimpleFit.Gyms.VerificationAuthority.Disabled do
  @moduledoc """
  The only authority of a production build (SF-136): there is none. Whatever the
  caller presents, the answer is the same and reveals nothing.
  """

  @behaviour SimpleFit.Gyms.VerificationAuthority

  @impl true
  def available?, do: false

  @impl true
  def ambient_credential, do: nil

  @impl true
  def authenticate(_credential, _permission), do: {:error, :review_disabled}
end
