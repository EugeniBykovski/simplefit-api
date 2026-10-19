defmodule SimpleFit.Repo.Migrations.AddCoachInvitationsRecipientIndex do
  use Ecto.Migration

  # SF-73: the recipient's inbox reads invitations by recipient digest
  # (the digests of the viewer's verified email identities), newest first.
  # The existing indexes lead with the coach or the token, so without this
  # the inbox would scan every invitation.
  def change do
    create index(:coach_invitations, [:recipient_digest, "inserted_at DESC", "id DESC"],
             name: :coach_invitations_recipient_index
           )
  end
end
