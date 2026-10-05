defmodule SimpleFit.Repo do
  use Ecto.Repo,
    otp_app: :simple_fit,
    adapter: Ecto.Adapters.Postgres
end
