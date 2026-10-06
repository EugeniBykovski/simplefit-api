defmodule SimpleFit.Accounts.EmailAddress do
  @moduledoc """
  The canonical SimpleFit email address policy (ADR 0009).

  `normalize/1` turns user input into the single canonical form used as the
  email identity key:

    1. Surrounding whitespace is trimmed.
    2. The address must be printable ASCII with no inner whitespace.
       Internationalized addresses (Unicode local parts or domains) are not
       accepted yet; a domain in punycode (`xn--...`) is.
    3. The whole address is lowercased (ASCII only), local part included, so
       `User@Example.com` and `user@example.com` are the same identity. This
       is SimpleFit's identity policy, not a claim that SMTP local parts are
       case-insensitive.
    4. The result must be structurally usable: exactly one `@`; a local part
       of 1-64 characters from the RFC 5322 dot-atom set, without leading,
       trailing or consecutive dots (quoted local parts are not accepted); a
       domain of at least two dot-separated labels of 1-63 characters
       (`a-z`, `0-9`, inner `-`); at most 254 characters in total.

  Nothing else is rewritten. Dots and `+tags` are kept, and provider aliases
  are never collapsed: `j.doe@gmail.com`, `jdoe@gmail.com` and
  `jdoe+box@gmail.com` are three different addresses, because collapsing them
  could merge distinct people.
  """

  @max_length 254
  @local_part ~r/\A[a-z0-9!#$%&'*+\/=?^_`{|}~-]+(\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*\z/
  @domain_label ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
  @printable_ascii ~r/\A[\x21-\x7e]+\z/

  @doc "Returns the canonical form of an email address, or `:error`."
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(address) when is_binary(address) do
    candidate = address |> String.trim() |> String.downcase(:ascii)

    if valid?(candidate), do: {:ok, candidate}, else: :error
  end

  def normalize(_address), do: :error

  defp valid?(address) do
    byte_size(address) <= @max_length and Regex.match?(@printable_ascii, address) and
      case String.split(address, "@") do
        [local, domain] -> valid_local?(local) and valid_domain?(domain)
        _not_exactly_one_at -> false
      end
  end

  defp valid_local?(local), do: byte_size(local) in 1..64 and Regex.match?(@local_part, local)

  defp valid_domain?(domain) do
    labels = String.split(domain, ".")
    length(labels) >= 2 and Enum.all?(labels, &Regex.match?(@domain_label, &1))
  end
end
