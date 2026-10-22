defmodule SimpleFitWeb.EmailIdentityController do
  @moduledoc """
  The viewer's email identities and verified email identity linking (SF-77,
  ADR 0024). The user and the session come from the access token only; no
  user or identity id is accepted. The rules live in `SimpleFit.Accounts`.
  """

  use SimpleFitWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.{Header, Schema}
  alias SimpleFit.Accounts
  alias SimpleFitWeb.{APIError, ApiSpec, ClientIP, Schemas}
  alias SimpleFitWeb.Plugs.Authenticate

  tags ["Account"]

  @security [%{"bearerAuth" => []}]

  @rate_limited {"Too many requests", "application/json", Schemas.ErrorResponse,
                 headers: %{
                   "retry-after" => %Header{
                     description: "Seconds until another request is accepted.",
                     schema: %Schema{type: :integer}
                   }
                 }}

  operation :index,
    operation_id: "listMyEmailIdentities",
    summary: "My email identities",
    description: """
    The viewer's email identities, oldest first: addresses whose ownership was proven with a code (at email
    registration, or linked with `requestMyEmailIdentityLink` and `confirmMyEmailIdentityLink`). Coach invitations
    sent to these addresses reach the viewer (`listMyIncomingCoachInvitations`). Google and Apple sign-ins are
    not listed; an email a provider reported is never an identity.
    """,
    security: @security,
    responses: [
      ok: {"The viewer's email identities", "application/json", Schemas.EmailIdentityList},
      unauthorized: ApiSpec.error_response("unauthorized"),
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def index(conn, _params) do
    render(conn, :index, identities: Accounts.list_email_identities(conn.assigns.current_user))
  end

  operation :request_link,
    operation_id: "requestMyEmailIdentityLink",
    summary: "Send a code to link an email address to my account",
    description: """
    Starts adding `email` as an email identity of the signed-in account (for example to a Google or Apple
    account) by sending a 6-digit code to it. The code only works in this account and this session, for this
    address; it never signs anyone in and is not an email sign-in or registration code.

    The response is the same for every well-formed address, including one that already belongs to this or
    another account: whether the address can be linked is only answered after the code proves the mailbox
    (`confirmMyEmailIdentityLink`). Requesting again (for any address) replaces the previous code.

    * `rate_limited` - per address, per account and per client limits (with `retry-after`).
    """,
    security: @security,
    request_body:
      {"Email address", "application/json", Schemas.EmailIdentityLinkRequest, required: true},
    responses: [
      accepted: {"Code requested", "application/json", Schemas.EmailIdentityLinkAccepted},
      unauthorized: ApiSpec.error_response("unauthorized"),
      unprocessable_entity: ApiSpec.error_response("validation_error"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def request_link(conn, params) do
    with {:ok, result} <-
           Accounts.request_email_identity_link(
             conn.assigns.current_user,
             conn.assigns.current_session,
             params["email"],
             ClientIP.limit_key(conn)
           ) do
      conn |> put_status(:accepted) |> render(:accepted, result: result)
    end
    |> respond(conn)
  end

  operation :confirm_link,
    operation_id: "confirmMyEmailIdentityLink",
    summary: "Link an email address to my account with its code",
    description: """
    Adds `email` as an email identity of the signed-in account once the 6-digit code sent to it by
    `requestMyEmailIdentityLink` is entered, in the same session. Nothing else changes: no account is created or
    merged, no session is issued, existing Google and Apple sign-ins stay as they are, and coach invitations to the
    address become visible but still need an explicit response with every usual requirement.

    * `code_invalid` - wrong code (or a code for another address). After 5 wrong codes the code stops working.
    * `code_expired` - the code expired, was replaced, was already used, stopped working, or was requested in
      another session: request a new one.
    * `conflict` - the address is an identity of another account. It is never moved; only reachable with the
      correct code.
    * `unauthorized` - the session is no longer valid (signed out or revoked).
    """,
    security: @security,
    request_body:
      {"Email address and code", "application/json", Schemas.EmailIdentityLinkConfirmRequest,
       required: true},
    responses: [
      ok:
        {"The address is an identity of this account", "application/json",
         Schemas.EmailIdentityLinkResult},
      unauthorized: ApiSpec.error_response("unauthorized"),
      conflict: ApiSpec.error_response("conflict"),
      unprocessable_entity: ApiSpec.error_response("code_invalid"),
      too_many_requests: @rate_limited,
      internal_server_error: ApiSpec.error_response("internal_error")
    ]

  def confirm_link(conn, params) do
    with {:ok, result} <-
           Accounts.confirm_email_identity_link(
             conn.assigns.current_user,
             conn.assigns.current_session,
             params["email"],
             params["code"],
             ClientIP.limit_key(conn)
           ) do
      render(conn, :linked, result: result)
    end
    |> respond(conn)
  end

  # Expected outcomes map to catalogued codes; changesets, conflicts and
  # limits go to the fallback controller.
  defp respond(%Plug.Conn{} = conn, _original), do: conn

  defp respond({:error, reason}, conn) when reason in [:code_invalid, :code_expired],
    do: APIError.send_error(conn, Atom.to_string(reason))

  defp respond({:error, :unauthorized}, conn), do: Authenticate.unauthorized(conn)

  defp respond({:error, _reason} = error, conn),
    do: SimpleFitWeb.FallbackController.call(conn, error)
end
