defmodule SimpleFit.Email.MessageTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Email.Message

  @valid [to: "fighter@example.com", subject: "Welcome", text: "Hello"]

  test "builds a valid message and wraps a single recipient" do
    assert {:ok, %Message{to: ["fighter@example.com"], subject: "Welcome", text: "Hello"}} =
             Message.new(@valid)

    assert {:ok, _} =
             Message.new(
               Keyword.merge(@valid,
                 to: ["A <a@example.com>", "b@example.com"],
                 html: "<p>Hi</p>"
               )
             )
  end

  test "rejects invalid messages" do
    for invalid <- [
          Keyword.delete(@valid, :to),
          Keyword.put(@valid, :to, []),
          Keyword.put(@valid, :to, "not-an-address"),
          Keyword.put(@valid, :to, Enum.map(1..51, &"user#{&1}@example.com")),
          Keyword.put(@valid, :subject, ""),
          Keyword.put(@valid, :subject, "Hi\r\nBcc: victim@example.com"),
          Keyword.put(@valid, :text, nil),
          Keyword.merge(@valid, text: "", html: ""),
          Keyword.put(@valid, :reply_to, "Support <support@example.com>\r\nX: y"),
          Keyword.put(@valid, :from, "nobody")
        ] do
      assert Message.new(invalid) == {:error, :invalid_request}, inspect(invalid)
    end
  end

  test "rejects header injection through recipients" do
    assert Message.new(Keyword.put(@valid, :to, "a@example.com\nBcc: b@example.com")) ==
             {:error, :invalid_request}
  end

  test "round-trips through the JSON-safe job representation" do
    {:ok, message} =
      Message.new(Keyword.merge(@valid, html: "<p>Hello</p>", reply_to: "help@example.com"))

    map = Message.to_map(message)

    assert map == %{
             "to" => ["fighter@example.com"],
             "subject" => "Welcome",
             "text" => "Hello",
             "html" => "<p>Hello</p>",
             "reply_to" => "help@example.com"
           }

    assert map |> Jason.encode!() |> Jason.decode!() |> Message.from_map() == {:ok, message}
    assert Message.from_map(%{"to" => "x"}) == {:error, :invalid_request}
  end

  test "mailbox?/1" do
    assert Message.mailbox?("a@b.co")
    assert Message.mailbox?("SimpleFit <no-reply@simplefit.com>")
    refute Message.mailbox?("SimpleFit <>")
    refute Message.mailbox?("a@b")
    refute Message.mailbox?(nil)
  end
end
