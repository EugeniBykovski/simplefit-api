defmodule SimpleFit.Observability.Redaction do
  @moduledoc """
  The one free-text redactor for logs and Sentry (SF-29, ADR 0019).

  Structured outputs never carry credentials or personal data by design
  (metadata allow-lists, no request bodies, `log: false` secret queries).
  This is the defence in depth for text nobody wrote on purpose: exception
  messages, crash reports and `inspect/1` output of an unexpected failure.
  It replaces, in any text:

    * SimpleFit credentials by their format: access (`sfa_`), refresh
      (`sfr_`), email link (`sfv_`), registration (`sfg_`), coach
      invitation (`sfi_`, SF-57), gym staff invitation (`sfs_`, SF-93) and gym
      member invitation (`sgm_`, SF-95)
      tokens;
    * JSON Web Tokens (Google and Apple identity tokens);
    * `Bearer` / `Basic` authorization values;
    * the value of a credential or personal-data key, in `key=value`,
      `key: value`, `inspect`'s `"key" => "value"` and Erlang's
      `key => <<"value">>` (OTP crash reports) forms (tokens, codes, nonces,
      cookies, secrets, emails, names, dates of birth);
    * email addresses;
    * AWS signatures and access key ids, and Resend API keys.

  Values are replaced, never shortened: no fragment of a secret survives.
  """

  @sensitive_keys ~w(password passwd secret token access_token refresh_token id_token
                     identity_token registration_token link_token authorization_code
                     authorization api_key apikey access_key code nonce cookie csrf email
                     full_name date_of_birth csv join_code)
  @keys Enum.join(@sensitive_keys, "|")

  @redactions [
    # inspect/1 maps and keyword lists: "token" => "...", token: "...".
    {~r/(["']?\b(?:#{@keys})\b["']?\s*(?:=>|:)\s*)"(?:[^"\\]|\\.)*"/i, "\\1\"[REDACTED]\""},
    # Erlang-formatted terms (OTP crash reports): code => <<"...">>.
    {~r/(\b(?:#{@keys})\b\s*=>\s*)<<"(?:[^"\\]|\\.)*">>/i, "\\1<<\"[REDACTED]\">>"},
    {~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/i, "\\1 [REDACTED]"},
    {~r/\b(?:sf[agirsv]|sgm)_[A-Za-z0-9._~+\/=-]+/, "[REDACTED]"},
    {~r/\beyJ[A-Za-z0-9_-]{2,}\.[A-Za-z0-9_-]{2,}\.[A-Za-z0-9_-]*/, "[REDACTED]"},
    {~r/\b(X-Amz-(?:Signature|Credential|Security-Token))=[^&\s"']+/i, "\\1=[REDACTED]"},
    {~r/\b(#{@keys})(["']?\s*[:=]\s*["']?)[^\s&"',}\]]+/i, "\\1\\2[REDACTED]"},
    {~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/, "[EMAIL]"},
    {~r/\bAKIA[0-9A-Z]{16}\b/, "[REDACTED]"},
    {~r/\bre_[A-Za-z0-9_]{16,}\b/, "[REDACTED]"}
  ]

  @doc "Redacts credentials and personal data from free text; other terms pass through."
  @spec redact(term()) :: term()
  def redact(text) when is_binary(text) do
    Enum.reduce(@redactions, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def redact(other), do: other
end
