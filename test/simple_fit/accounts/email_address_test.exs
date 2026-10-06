defmodule SimpleFit.Accounts.EmailAddressTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Accounts.EmailAddress

  describe "normalize/1" do
    test "trims surrounding whitespace and lowercases the whole address" do
      assert EmailAddress.normalize(" User@Example.com ") == {:ok, "user@example.com"}
      assert EmailAddress.normalize("\tUSER@EXAMPLE.COM\n") == {:ok, "user@example.com"}
      assert EmailAddress.normalize("user@example.com") == {:ok, "user@example.com"}
    end

    test "is deterministic and idempotent" do
      {:ok, once} = EmailAddress.normalize("  Mixed.Case+Tag@Sub.Example.ORG ")
      assert once == "mixed.case+tag@sub.example.org"
      assert EmailAddress.normalize(once) == {:ok, once}
    end

    test "keeps dots and plus tags (no provider-specific aliasing)" do
      assert EmailAddress.normalize("j.doe@gmail.com") == {:ok, "j.doe@gmail.com"}
      assert EmailAddress.normalize("jdoe+boxing@gmail.com") == {:ok, "jdoe+boxing@gmail.com"}

      assert EmailAddress.normalize("J.Doe+Boxing@GoogleMail.com") ==
               {:ok, "j.doe+boxing@googlemail.com"}

      refute EmailAddress.normalize("j.doe@gmail.com") == EmailAddress.normalize("jdoe@gmail.com")

      refute EmailAddress.normalize("jdoe+boxing@gmail.com") ==
               EmailAddress.normalize("jdoe@gmail.com")
    end

    test "accepts RFC 5322 dot-atom local parts and punycode domains" do
      assert {:ok, _} = EmailAddress.normalize("o'brien_99!#$%&*/=?^`{|}~-@example.co.uk")
      assert {:ok, _} = EmailAddress.normalize("user@xn--bcher-kva.example")
      assert {:ok, _} = EmailAddress.normalize("user@sub-domain.example")
    end

    test "rejects structurally unusable addresses" do
      for invalid <- [
            "",
            "   ",
            "user",
            "user@",
            "@example.com",
            "user@@example.com",
            "a@b@example.com",
            "user@localhost",
            "user@example..com",
            "user@-example.com",
            "user@example-.com",
            ".user@example.com",
            "user.@example.com",
            "us..er@example.com",
            "us er@example.com",
            "user@exa mple.com",
            ~s("quoted"@example.com),
            "user@[127.0.0.1]"
          ] do
        assert EmailAddress.normalize(invalid) == :error,
               "expected #{inspect(invalid)} to be rejected"
      end
    end

    test "rejects non-ASCII addresses (internationalized email is not supported yet)" do
      assert EmailAddress.normalize("józef@example.com") == :error
      assert EmailAddress.normalize("user@bücher.example") == :error
    end

    test "enforces the RFC length limits" do
      local64 = String.duplicate("a", 64)
      assert {:ok, _} = EmailAddress.normalize("#{local64}@example.com")
      assert EmailAddress.normalize("#{local64}a@example.com") == :error

      label63 = String.duplicate("b", 63)
      assert {:ok, _} = EmailAddress.normalize("u@#{label63}.com")
      assert EmailAddress.normalize("u@#{label63}b.com") == :error

      long_domain = Enum.map_join(1..4, ".", fn _ -> label63 end)
      assert EmailAddress.normalize("u@#{long_domain}") == :error
    end

    test "rejects non-strings" do
      assert EmailAddress.normalize(nil) == :error
      assert EmailAddress.normalize(:"user@example.com") == :error
      assert EmailAddress.normalize(123) == :error
    end
  end
end
