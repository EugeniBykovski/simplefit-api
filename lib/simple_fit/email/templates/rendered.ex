defmodule SimpleFit.Email.Templates.Rendered do
  @moduledoc """
  A rendered transactional email: subject, preheader, HTML and plain text
  (ADR 0011). Turn it into a `SimpleFit.Email.Message` with
  `SimpleFit.Email.Templates.to_message/2`.

  Rendered content can carry one-time codes and credential-bearing URLs, so
  `inspect/2` shows only the template id.
  """

  @derive {Inspect, only: [:template]}
  @enforce_keys [:template, :subject, :preheader, :html, :text]
  defstruct [:template, :subject, :preheader, :html, :text]

  @type t :: %__MODULE__{
          template: atom(),
          subject: String.t(),
          preheader: String.t(),
          html: String.t(),
          text: String.t()
        }
end
