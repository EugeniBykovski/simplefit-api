defmodule SimpleFit.Storage.ObjectKeyTest do
  use ExUnit.Case, async: true

  alias SimpleFit.Storage.ObjectKey

  doctest ObjectKey

  test "builds keys from safe segments" do
    assert ObjectKey.build(["gyms", "9f1c2b", "cover.v2.webp"]) ==
             {:ok, "gyms/9f1c2b/cover.v2.webp"}

    assert ObjectKey.valid?("training-media/2026/clip_01.mp4")
  end

  test "rejects traversal, absolute paths and unsafe characters" do
    for segments <- [
          [],
          [""],
          [".."],
          ["a", "../b"],
          ["/etc", "passwd"],
          ["a b"],
          ["a\nb"],
          ["a?b"],
          ["a%2F..%2Fb"],
          [".hidden"],
          ["ünïcode"],
          [String.duplicate("a", 129)],
          ["a", nil]
        ] do
      assert ObjectKey.build(segments) == {:error, :invalid_request}, inspect(segments)
    end

    refute ObjectKey.valid?("/leading")
    refute ObjectKey.valid?("trailing/")
    refute ObjectKey.valid?("a//b")
    refute ObjectKey.valid?(nil)
    refute ObjectKey.valid?(String.duplicate("a/", 600) <> "a")
  end
end
