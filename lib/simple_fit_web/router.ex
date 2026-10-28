defmodule SimpleFitWeb.Router do
  use SimpleFitWeb, :router

  # Routing layout (see docs/architecture/adr/0003-api-versioning-and-errors.md):
  #
  #   /api/health, /api/openapi, /api/docs   operational, unversioned
  #   /api/me, /api/auth/...                 session and viewer, unversioned (ADR 0010)
  #   /dev/emails                            email template preview, development only (ADR 0011)
  #   /api/v1/...                            product resources: /me/account-profile,
  #                                          /me/email-identities, /me/fighter-profile,
  #                                          /me/coach-profile, /me/entry, /me/first-run,
  #                                          /gyms/{gym_id}/... (tenant-scoped, ADR 0026)

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SimpleFitWeb.ApiSpec
  end

  # Requires a valid SimpleFit access token (Authorization: Bearer sfa_...).
  # Every answer is personal data: `no-store` keeps it out of HTTP caches,
  # which Phoenix's default `private` still allows (OkHttp on Android, the iOS
  # dev-client network inspector, browsers; SF-70, ADR 0010).
  pipeline :authenticated do
    plug :no_store
    plug SimpleFitWeb.Plugs.Authenticate
  end

  pipeline :api_docs do
    plug :require_api_docs_enabled
  end

  pipeline :api_docs_page do
    plug :accepts, ["html"]
  end

  scope "/api", SimpleFitWeb do
    pipe_through :api

    get "/health", HealthController, :show

    post "/auth/session/refresh", SessionController, :refresh
    post "/auth/logout", SessionController, :logout

    # Passwordless email authentication (ADR 0012).
    post "/auth/email/registrations", EmailAuthController, :request_registration
    post "/auth/email/registrations/verify", EmailAuthController, :verify_registration
    post "/auth/email/registrations/status", EmailAuthController, :registration_status
    post "/auth/email/verification-links/verify", EmailAuthController, :verify_link
    post "/auth/email/sign-in", EmailAuthController, :request_sign_in
    post "/auth/email/sign-in/verify", EmailAuthController, :verify_sign_in

    # Google sign-in (ADR 0013).
    post "/auth/google", GoogleAuthController, :authenticate
    # Sign in with Apple (ADR 0014).
    post "/auth/apple", AppleAuthController, :authenticate
  end

  scope "/api", SimpleFitWeb do
    pipe_through [:api, :authenticated]

    get "/me", MeController, :show
  end

  # Product resources (ADR 0003). SF-25: the viewer's fighter profile and
  # resumable Fighter onboarding (ADR 0015).
  scope "/api/v1", SimpleFitWeb do
    pipe_through [:api, :authenticated]

    # SF-44: shared account registration, basics and consents (ADR 0016).
    get "/me/account-profile", AccountProfileController, :show
    patch "/me/account-profile", AccountProfileController, :update

    post "/me/account-profile/complete-registration",
         AccountProfileController,
         :complete_registration

    # SF-77: the viewer's email identities and verified email identity
    # linking (ADR 0024). The user and session come from the token only.
    get "/me/email-identities", EmailIdentityController, :index
    post "/me/email-identities/link-challenge", EmailIdentityController, :request_link
    post "/me/email-identities/confirm-link", EmailIdentityController, :confirm_link

    get "/me/fighter-profile", FighterProfileController, :show
    patch "/me/fighter-profile", FighterProfileController, :update
    post "/me/fighter-profile/complete-onboarding", FighterProfileController, :complete_onboarding

    # SF-50: the viewer's coach profile and resumable Coach onboarding (ADR 0020).
    get "/me/coach-profile", CoachProfileController, :show
    patch "/me/coach-profile", CoachProfileController, :update
    post "/me/coach-profile/complete-onboarding", CoachProfileController, :complete_onboarding

    # SF-45: post-authentication entry resolution (ADR 0017).
    get "/me/entry", EntryController, :show
    # SF-51: the last explicitly chosen profile context (ADR 0017 amendment).
    put "/me/entry/context", EntryController, :choose_context

    # SF-56: Coach–Fighter relationships (ADR 0021). No create operation:
    # only a fighter's acceptance (Invitation task) activates a relationship.
    get "/me/coach/fighters", CoachFighterController, :index
    get "/me/coach/fighters/:relationship_id", CoachFighterController, :show
    post "/me/coach/fighters/:relationship_id/end", CoachFighterController, :end_relationship
    get "/me/coaches", MyCoachController, :index
    get "/me/coaches/:relationship_id", MyCoachController, :show
    post "/me/coaches/:relationship_id/end", MyCoachController, :end_relationship

    # SF-57: coach invitations and the recipient's explicit response. The only
    # public ways a relationship comes to exist are acceptCoachInvitation and
    # (SF-73, off until SF-72) acceptMyIncomingCoachInvitation, which share
    # one transaction.
    get "/me/coach/data-rules", CoachInvitationController, :data_rules
    post "/me/coach/data-rules/acknowledge", CoachInvitationController, :acknowledge_data_rules
    post "/me/coach/invitations", CoachInvitationController, :create
    get "/me/coach/invitations", CoachInvitationController, :index
    post "/me/coach/invitations/:invitation_id/resend", CoachInvitationController, :resend
    post "/me/coach/invitations/:invitation_id/cancel", CoachInvitationController, :cancel
    # SF-73: the invitations addressed to the viewer's verified email identities.
    get "/me/coach-invitations", CoachInvitationResponseController, :index

    get "/me/coach-invitations/:invitation_id/preview",
        CoachInvitationResponseController,
        :preview_incoming

    post "/me/coach-invitations/:invitation_id/accept",
         CoachInvitationResponseController,
         :accept_incoming

    post "/me/coach-invitations/:invitation_id/decline",
         CoachInvitationResponseController,
         :decline_incoming

    post "/me/coach-invitations/accept", CoachInvitationResponseController, :accept
    post "/me/coach-invitations/decline", CoachInvitationResponseController, :decline

    # SF-62: training sessions (ADR 0023). One session for one fighter of an
    # active relationship; SF-63: the fighter completes their own.
    post "/me/coach/training-sessions", CoachTrainingSessionController, :create
    get "/me/coach/training-sessions", CoachTrainingSessionController, :index
    get "/me/coach/training-sessions/:session_id", CoachTrainingSessionController, :show
    patch "/me/coach/training-sessions/:session_id", CoachTrainingSessionController, :update
    post "/me/coach/training-sessions/:session_id/cancel", CoachTrainingSessionController, :cancel
    # SF-83: gyms (ADR 0026). Every gym-scoped operation names the gym in the
    # path; access comes from the viewer's active staff membership there.
    post "/gyms", GymController, :create
    get "/me/gyms", GymController, :index
    get "/gyms/:gym_id", GymController, :show
    # SF-85: gym owner registration and setup (draft -> completed).
    get "/gyms/:gym_id/setup", GymSetupController, :show
    patch "/gyms/:gym_id/setup", GymSetupController, :update
    put "/gyms/:gym_id/setup/primary-location", GymSetupController, :put_primary_location
    post "/gyms/:gym_id/complete-setup", GymSetupController, :complete
    delete "/gyms/:gym_id", GymSetupController, :discard
    # SF-90: the owner's first run and the setup checklist.
    get "/gyms/:gym_id/first-run", GymFirstRunController, :show
    post "/gyms/:gym_id/first-run/start", GymFirstRunController, :start
    post "/gyms/:gym_id/first-run/complete", GymFirstRunController, :complete
    post "/gyms/:gym_id/first-run/dismiss", GymFirstRunController, :dismiss

    get "/me/training-sessions", MyTrainingSessionController, :index
    get "/me/training-sessions/:session_id", MyTrainingSessionController, :show
    post "/me/training-sessions/:session_id/complete", MyTrainingSessionController, :complete

    # SF-40: one-time first-run experiences (ADR 0018).
    get "/me/first-run", FirstRunController, :index
    put "/me/first-run/:experience", FirstRunController, :record
  end

  # SF-57: what an invitation link shows before sign-in (token in the body,
  # rate limited, nothing about the recipient).
  scope "/api/v1", SimpleFitWeb do
    pipe_through :api

    post "/coach-invitations/preview", CoachInvitationResponseController, :preview

    # SF-72: published legal documents for the public pages (ADR 0022).
    get "/legal-documents/:document_id", LegalDocumentController, :show
    get "/legal-documents/:document_id/versions/:version", LegalDocumentController, :show_version
  end

  scope "/api" do
    pipe_through [:api_docs, :api]

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", SimpleFitWeb do
    pipe_through [:api_docs, :api_docs_page]

    get "/docs", ApiDocsController, :show
  end

  # Development-only transactional email preview (ADR 0011).
  pipeline :email_previews do
    plug :require_email_previews_enabled
  end

  scope "/dev/emails", SimpleFitWeb do
    pipe_through :email_previews

    get "/", EmailPreviewController, :index
    get "/:id", EmailPreviewController, :show
  end

  # Docs routes answer exactly like an unknown route when disabled, so a
  # production deployment does not reveal that they exist.
  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp require_api_docs_enabled(conn, _opts) do
    if Application.get_env(:simple_fit, :api_docs, [])[:enabled] do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end
  end

  # Enabled only by config/dev.exs (never from the environment), so the
  # previews cannot be switched on in production.
  defp require_email_previews_enabled(conn, _opts) do
    if Application.get_env(:simple_fit, :email_previews, [])[:enabled] do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__
    end
  end
end
