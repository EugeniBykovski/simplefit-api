defmodule SimpleFit.VerificationHelpers do
  @moduledoc """
  Fixtures for gym business verification tests (SF-103): applications and
  documents through the real `SimpleFit.Gyms` functions, with storage's
  server-side `HEAD`/`DELETE` answered by a `Req.Test` stub that serves the
  objects the test "uploaded". No fixture marks anything approved: only
  `SimpleFit.Gyms.VerificationReview` (the operator path) decides.
  """

  import ExUnit.Assertions

  alias SimpleFit.Accounts.User
  alias SimpleFit.{GymHelpers, Gyms}
  alias SimpleFit.Gyms.VerificationReview

  @operator "reviewer@trust.simplefit.test"

  @doc "An operator address unrelated to any gym."
  @spec operator() :: String.t()
  def operator, do: @operator

  @doc "Valid business details."
  @spec details(map()) :: map()
  def details(overrides \\ %{}) do
    Map.merge(
      %{
        "legal_name" => "Simple Boxing Sp. z o.o.",
        "registration_country" => "pl",
        "registration_number" => "0000123456",
        "address_line" => "Ząbkowska 12",
        "postal_code" => "03-736",
        "city" => "Warszawa",
        "website" => "https://simpleboxing.example"
      },
      overrides
    )
  end

  @doc """
  Serves stored objects to the storage stub, by object key suffix (the
  evidence id): `%{evidence_id => {byte_size, content_type}}`. Anything else
  is a 404. `DELETE` answers 204 and is reported to `test_pid` as
  `{:storage_deleted, path}`.
  """
  @spec stub_storage(map(), pid()) :: :ok
  def stub_storage(objects, test_pid \\ self()) do
    Req.Test.stub(SimpleFit.Storage, fn conn ->
      evidence_id = conn.request_path |> String.split("/") |> List.last()

      case {conn.method, Map.get(objects, evidence_id)} do
        {"HEAD", {size, type}} ->
          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(size))
          |> Plug.Conn.put_resp_header("content-type", type)
          |> Plug.Conn.send_resp(200, "")

        {"HEAD", nil} ->
          Plug.Conn.send_resp(conn, 404, "")

        {"DELETE", _} ->
          send(test_pid, {:storage_deleted, conn.request_path})
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    :ok
  end

  @doc "Starts the owner's draft with `details/1`."
  @spec draft!(User.t(), Ecto.UUID.t(), map()) :: map()
  def draft!(%User{} = owner, gym_id, attrs \\ details()) do
    {:ok, {view, :created}} =
      Gyms.save_business_verification(owner, GymHelpers.live_session!(owner), gym_id, attrs)

    view
  end

  @doc """
  Announces a PDF, "uploads" it (the stub serves it) and confirms it.
  Returns `{view, evidence_id}`. `objects` accumulates across calls when
  passed back in.
  """
  @spec upload!(User.t(), Ecto.UUID.t(), map()) :: {map(), Ecto.UUID.t(), map()}
  def upload!(%User{} = owner, gym_id, objects \\ %{}) do
    session = GymHelpers.live_session!(owner)
    {:ok, current} = Gyms.get_business_verification(owner, gym_id)

    {:ok, {_view, evidence, upload}} =
      Gyms.add_business_verification_evidence(owner, session, gym_id, %{
        "revision" => current.application.revision,
        "kind" => "registration_extract",
        "file_name" => "registry-extract.pdf",
        "content_type" => "application/pdf",
        "byte_size" => 182_311
      })

    assert upload.headers["content-length"] == "182311"
    objects = Map.put(objects, evidence.id, {182_311, "application/pdf"})
    stub_storage(objects)

    {:ok, view} = Gyms.confirm_business_verification_evidence(owner, session, gym_id, evidence.id)
    {view, evidence.id, objects}
  end

  @doc "A submitted application of `gym_id` (draft, one confirmed PDF, submit)."
  @spec submitted!(User.t(), Ecto.UUID.t()) :: map()
  def submitted!(%User{} = owner, gym_id) do
    draft!(owner, gym_id)
    {view, _evidence_id, _objects} = upload!(owner, gym_id)

    {:ok, view} =
      Gyms.submit_business_verification(owner, GymHelpers.live_session!(owner), gym_id, %{
        "revision" => view.application.revision
      })

    view
  end

  @doc "Submits, then approves as the operator (the real review path)."
  @spec approved!(User.t(), Ecto.UUID.t()) :: map()
  def approved!(%User{} = owner, gym_id) do
    view = submitted!(owner, gym_id)

    {:ok, _application} =
      VerificationReview.decide(view.application.id, :approved,
        revision: view.application.revision,
        operator: @operator
      )

    {:ok, view} = Gyms.get_business_verification(owner, gym_id)
    view
  end
end
