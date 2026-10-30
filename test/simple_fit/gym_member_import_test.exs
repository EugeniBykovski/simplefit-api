defmodule SimpleFit.GymMemberImportTest do
  @moduledoc """
  The member-list foundation (SF-95): the CSV reader, column mapping,
  validation, deduplication and classification against the gym's own
  facts, as a dry run that persists, sends and logs nothing.
  """

  use SimpleFit.DataCase, async: true

  import ExUnit.CaptureLog
  import SimpleFit.GymHelpers

  alias SimpleFit.{Gyms, Repo}
  alias SimpleFit.Gyms.{AuditEvent, Csv, Member, MemberInvitation}

  describe "Csv.parse/1" do
    test "comma, semicolon and tab; quotes, doubled quotes, embedded breaks; BOM; blank lines" do
      assert {:ok,
              %{
                delimiter: ",",
                header: ["name", "email"],
                rows: [{2, ["Marta", "m@example.com"]}]
              }} =
               Csv.parse("name,email\nMarta,m@example.com\n")

      assert {:ok, %{delimiter: ";", rows: [{2, ["Kowalska, Marta", "m@example.com"]}]}} =
               Csv.parse(
                 <<0xEF, 0xBB, 0xBF>> <>
                   "imię i nazwisko;email\r\n\"Kowalska, Marta\";m@example.com\r\n"
               )

      assert {:ok, %{delimiter: "\t"}} = Csv.parse("name\temail\nA\tb@example.com")

      assert {:ok,
              %{rows: [{2, ["say \"hi\"\nthere", "x@example.com"]}, {5, ["B", "y@example.com"]}]}} =
               Csv.parse(~s(name,email\n"say ""hi""\nthere",x@example.com\n\nB,y@example.com))
    end

    test "rejects what it cannot read, naming only a code and a line" do
      assert {:error, :empty} = Csv.parse("  \n ")
      assert {:error, :empty} = Csv.parse(nil)
      assert {:error, :invalid_encoding} = Csv.parse(<<"name,email\n", 0xFF, 0xFE>>)
      assert {:error, {:unterminated_quote, 2}} = Csv.parse("name,email\n\"open,x@example.com")
      assert {:error, {:stray_quote, 2}} = Csv.parse("name,email\nab\"c,x@example.com")
      assert {:error, :duplicate_header} = Csv.parse("email,Email\na,b")
      assert {:error, :blank_header} = Csv.parse("name,,email\na,b,c")
      assert {:error, :too_large} = Csv.parse(String.duplicate("a", 1_000_001))

      assert {:error, :too_many_rows} =
               Csv.parse("email\n" <> String.duplicate("a@example.com\n", 1001))

      assert {:error, :too_many_columns} = Csv.parse(Enum.map_join(1..31, ",", &"c#{&1}"))
      assert {:error, {:field_too_long, 2}} = Csv.parse("email\n" <> String.duplicate("a", 501))
    end
  end

  describe "preview" do
    setup do
      owner = registered_as!(registered!("import"), "Yauheni Bykovski")
      gym = completed_gym!(owner)
      %{owner: owner, gym: gym}
    end

    test "maps, validates, deduplicates and classifies against the gym's own facts only", ctx do
      code = join_code!(ctx.owner, ctx.gym.id)
      {member, _} = active_member!(ctx.owner, ctx.gym.id, code)
      [member_email] = SimpleFit.Accounts.verified_email_addresses(member)
      requester = email_user!(address("req"))
      {:ok, _, :created} = join(requester, code)
      [requester_email] = SimpleFit.Accounts.verified_email_addresses(requester)
      invited = address("invited")
      invite_member!(ctx.owner, ctx.gym.id, invited)

      # An account with no tie to this gym is just "ready": nothing about it leaks.
      stranger = email_user!(address("stranger"))
      [stranger_email] = SimpleFit.Accounts.verified_email_addresses(stranger)

      csv = """
      Imię i nazwisko;E-mail;Karnet;Telefon
      Anna Nowak;anna@example.com;Unlimited;+48 600 000 000
      Duplicate Anna; ANNA@Example.com ;;
      ;not-an-email;;
      No Email;;;
      Member;#{member_email};;
      Requester;#{requester_email};;
      Invited;#{invited};;
      Stranger;#{stranger_email};;
      """

      counts_before = counts()
      assert {:ok, preview} = Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{"csv" => csv})

      assert preview.persisted == false
      assert preview.commit == %{available: false, blocked_by: "legal_basis_pending"}
      assert preview.delimiter == ";"

      assert Enum.map(preview.columns, &{&1.header, &1.field, &1.status}) == [
               {"Imię i nazwisko", "name", :mapped},
               {"E-mail", "email", :mapped},
               {"Karnet", nil, :not_imported},
               {"Telefon", nil, :not_imported}
             ]

      assert Enum.map(preview.rows, &{&1.line, &1.outcome}) == [
               {2, :ready},
               {3, :duplicate},
               {4, :invalid_email},
               {5, :missing_email},
               {6, :already_member},
               {7, :request_pending},
               {8, :already_invited},
               {9, :ready}
             ]

      assert Enum.at(preview.rows, 1).duplicate_of_line == 2
      assert Enum.at(preview.rows, 0).email == "a•••@example.com"
      assert Enum.at(preview.rows, 3).name_present
      refute Enum.at(preview.rows, 2).name_present

      assert preview.summary == %{
               total: 8,
               ready: 2,
               duplicate: 1,
               invalid_email: 1,
               missing_email: 1,
               already_member: 1,
               request_pending: 1,
               already_invited: 1
             }

      encoded = inspect(preview)

      for secret <- ["anna@example.com", "+48", "Unlimited", "Anna Nowak", stranger_email],
          do: refute(encoded =~ secret)

      # A dry run: nothing written, nothing sent.
      assert counts() == counts_before
    end

    test "an explicit mapping wins; bad mappings and missing email columns are refused", ctx do
      csv = "kontakt,who\nx@example.com,X Y\n"

      assert {:error, %Ecto.Changeset{} = missing} =
               Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{"csv" => csv})

      assert missing.errors[:email_column]

      assert {:ok, %{rows: [%{outcome: :ready, name_present: true}]}} =
               Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{
                 "csv" => csv,
                 "mapping" => %{"email" => "kontakt", "name" => "who"}
               })

      for mapping <- [
            %{"email" => "nope"},
            %{"email" => "kontakt", "name" => "kontakt"},
            %{"phone" => "who"}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{
                   "csv" => csv,
                   "mapping" => mapping
                 })
      end

      assert {:error, %Ecto.Changeset{} = extra} =
               Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{"csv" => csv, "commit" => true})

      assert Enum.any?(extra.errors, fn {field, _} -> field == "commit" end)
    end

    test "parse errors are validation errors that never quote the content", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{
                 "csv" => "email\n\"secret@example.com"
               })

      assert {"unterminated_quote at line 2", [validation: :unterminated_quote]} =
               changeset.errors[:csv]

      assert {:error, %Ecto.Changeset{}} = Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{})
    end

    test "owner, managers and front desk; never coaches, outsiders or drafts", ctx do
      {coach, _} = joined_staff!(ctx.owner, ctx.gym.id, :coach)
      {desk, _} = joined_staff!(ctx.owner, ctx.gym.id, :front_desk)
      attrs = %{"csv" => "email\na@example.com"}

      assert {:ok, _} = Gyms.preview_member_import(desk, ctx.gym.id, attrs)
      assert {:error, :forbidden} = Gyms.preview_member_import(coach, ctx.gym.id, attrs)

      assert {:error, :not_found} =
               Gyms.preview_member_import(registered!("o"), ctx.gym.id, attrs)

      draft_owner = registered!("draft-import")
      draft = draft_gym!(draft_owner)
      assert {:error, {:conflict, _}} = Gyms.preview_member_import(draft_owner, draft.id, attrs)
    end

    test "never logs the list, and is rate limited per user", ctx do
      csv = "email\nlog-canary@example.com\n"

      log =
        capture_log([level: :debug], fn ->
          for _ <- 1..30,
              do: {:ok, _} = Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{"csv" => csv})
        end)

      refute log =~ "log-canary"

      assert {:error, {:rate_limited, _}} =
               Gyms.preview_member_import(ctx.owner, ctx.gym.id, %{"csv" => csv})
    end
  end

  defp counts do
    for schema <- [Member, MemberInvitation, AuditEvent, SimpleFit.Accounts.User, Oban.Job],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end
end
