defmodule SimpleFit.Email.Templates.Layout do
  @moduledoc """
  Email-safe rendering of the shared SimpleFit email layout (ADR 0011).

  Templates describe their body as a list of blocks; this module renders the
  same blocks twice: as table-based HTML with inline styles, and as a
  readable plain-text part. The layout translates the Claude Design email
  frame (`project/Email*.dc.html`): a 600 px card on a stone background, a
  dark header bar with the SimpleFit wordmark and a category tag, the body,
  and the footer.

  Every dynamic string is HTML-escaped here; templates never build markup.
  URLs reach `href` only after `SimpleFit.Email.Templates.Input` validated
  them.

  ## Blocks

    * `{:eyebrow, text}` / `{:eyebrow, text, :danger}`
    * `{:heading, text}` / `{:heading, text, size}` (`size` in px, default 26)
    * `{:paragraph, segments}` / `{:paragraph, segments, :small | :note | :lead}`
    * `{:button, label, url, :dark | :olive | :outline | :danger}`
    * `{:panel, blocks}` / `{:panel, blocks, :stone | :highlight | :quiet}`:
      rounded panel (stone, olive highlight, or light with a border)
    * `{:label, text}`: mono caption inside a panel
    * `{:code, code, size, align}`: one-time code, `size` in px
    * `{:caption, text, align}`: small caption under a code
      (`align` is `:center` or `:left`)
    * `{:display, text}`: large display line (a time, a date)
    * `{:mono, text}`: a monospaced value (an invite link)
    * `{:bullets, items, :olive | :muted | :check | :dash}`
    * `{:rows, [{label, value}]}`: label/value table
    * `{:steps, [{title, detail | nil}]}`: next steps, numbered in visible
      order
    * `{:progress, completed, total}`: a segmented progress bar (HTML only;
      the text part states progress in words elsewhere)
    * `{:stats, [{value, label}]}`: stat tiles
    * `{:identity, initials | nil, eyebrow, name, detail | nil}`: who sent
      the email (an initials avatar, a mono eyebrow, a name and a line)

  `nil` blocks, panel blocks and rows are dropped, so a template composes
  optional content without leaving empty spacing, labels or dividers: rows
  are separated by dividers between visible rows only.

  A segment is a string, `{:strong, text}`, `{:link, label, url}` or
  `{:link, label, url, :danger}`.

  ## Footers

  `:security`, `:activity`, `:invitation` (the design's fixed notes), or
  `{:member, preferences_url, unsubscribe_url}` for member emails, whose
  links are presentation data supplied by the sender.
  """

  @typedoc "Inline text with optional emphasis and links."
  @type segment ::
          String.t()
          | {:strong, String.t()}
          | {:link, String.t(), String.t()}
          | {:link, String.t(), String.t(), :danger | :footer}

  @type block ::
          {:eyebrow, String.t()}
          | {:eyebrow, String.t(), :danger}
          | {:heading, String.t()}
          | {:heading, String.t(), pos_integer()}
          | {:paragraph, [segment()]}
          | {:paragraph, [segment()], :small | :note | :lead}
          | {:button, String.t(), String.t(), :dark | :olive | :outline | :danger}
          | {:panel, [block()]}
          | {:panel, [block()], :stone | :highlight | :quiet}
          | {:label, String.t()}
          | {:code, String.t(), pos_integer(), :center | :left}
          | {:caption, String.t(), :center | :left}
          | {:display, String.t()}
          | {:mono, String.t()}
          | {:bullets, [String.t()], :olive | :muted | :check | :dash}
          | {:rows, [{String.t(), String.t()}]}
          | {:steps, [{String.t(), String.t() | nil}]}
          | {:progress, non_neg_integer(), pos_integer()}
          | {:stats, [{String.t(), String.t()}]}
          | {:identity, String.t() | nil, String.t(), String.t(), String.t() | nil}

  @typedoc "Which footer note the email carries."
  @type footer :: :security | :activity | :invitation | {:member, String.t(), String.t()}

  @typedoc "Layout parameters: category tag, preheader, footer kind."
  @type frame :: %{
          required(:subject) => String.t(),
          required(:preheader) => String.t(),
          required(:tag) => String.t(),
          required(:footer) => footer()
        }

  # Claude Design palette (Graphite × Olive, light email variant).
  @page "#DDDED4"
  @card "#F7F7F2"
  @bar "#111312"
  @bar_text "#EDEFE7"
  @bar_tag "#C9D17E"
  @ink "#1A1D1B"
  @body "#4A4F49"
  @muted "#6B7066"
  @olive "#5B6524"
  @olive_soft "#8A8F84"
  @olive_button "#AEB95A"
  @panel "#ECEDE5"
  @rule "#DCDDD3"
  @outline "#C9CBBE"
  @cta_text "#E4EAB8"
  @danger "#A23F27"
  @highlight "#E4EAB8"
  @quiet_panel "#F0F1EA"
  @avatar "#C9D17E"
  @avatar_text "#1C2010"
  @danger_button "#FBE9E4"
  @danger_border "#E07A5F"
  @progress_done "#5B6524"
  @progress_todo "#D6D8CB"

  # Web fonts are not reliable in email clients: each stack names the design
  # font first (used where installed) and falls back to system fonts.
  @display "Unbounded, 'Helvetica Neue', Helvetica, Arial, sans-serif"
  @text "Manrope, 'Helvetica Neue', Helvetica, Arial, sans-serif"
  @mono "'JetBrains Mono', Menlo, Consolas, 'Courier New', monospace"

  @footer_notes %{
    security: "This is a security email. You can’t unsubscribe from security emails.",
    activity: "You’re receiving this because of activity on your SimpleFit account.",
    invitation:
      "Someone invited this address. If you weren’t expecting it, ignore this email — no account is created."
  }

  @address "SimpleFit Boxing · Warsaw, Poland"

  @doc "Renders `blocks` in `frame` as the `Rendered` email of `template`."
  @spec render(atom(), frame(), [block()]) :: {:ok, SimpleFit.Email.Templates.Rendered.t()}
  def render(template, frame, blocks) do
    {:ok,
     %SimpleFit.Email.Templates.Rendered{
       template: template,
       subject: frame.subject,
       preheader: frame.preheader,
       html: html(frame, blocks),
       text: text(frame, blocks)
     }}
  end

  ## HTML

  @doc "The complete HTML document."
  @spec html(frame(), [block()]) :: String.t()
  def html(frame, blocks) do
    IO.iodata_to_binary([
      ~s(<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">\n),
      ~s(<meta name="x-apple-disable-message-reformatting">\n),
      ~s(<meta name="color-scheme" content="light">\n<meta name="supported-color-schemes" content="light">\n),
      "<title>",
      escape(frame.subject),
      "</title>\n",
      "<style>@media only screen and (max-width: 620px) {",
      ".sf-card { width: 100% !important; } ",
      ".sf-pad { padding-left: 24px !important; padding-right: 24px !important; }",
      "}</style>\n</head>\n",
      ~s(<body style="margin: 0; padding: 0; background-color: #{@page};">\n),
      preheader(frame.preheader),
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#{@page}" style="background-color: #{@page};">),
      ~s(<tr><td align="center" style="padding: 28px 12px;">),
      ~s(<table role="presentation" class="sf-card" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="#{@card}" style="width: 600px; max-width: 600px; background-color: #{@card}; border-radius: 18px;">),
      header(frame.tag),
      ~s(<tr><td class="sf-pad" style="padding: 36px 40px 14px; font-family: #{@text}; color: #{@body};">),
      blocks |> visible() |> Enum.map(&html_block/1),
      "</td></tr>",
      footer(frame.footer),
      "</table></td></tr></table>\n</body>\n</html>\n"
    ])
  end

  # Inbox preview text, hidden in the body.
  defp preheader(text) do
    [
      ~s(<div style="display: none; max-height: 0; overflow: hidden; mso-hide: all; font-size: 1px; line-height: 1px; color: #{@page}; opacity: 0;">),
      escape(text),
      "</div>\n"
    ]
  end

  defp header(tag) do
    [
      ~s(<tr><td bgcolor="#{@bar}" style="background-color: #{@bar}; padding: 22px 36px; border-radius: 18px 18px 0 0;">),
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>),
      ~s(<td style="font-family: #{@display}; font-size: 14px; font-weight: 600; color: #{@bar_text};">SimpleFit</td>),
      ~s(<td align="right" style="font-family: #{@mono}; font-size: 11px; letter-spacing: 0.16em; color: #{@bar_tag};">),
      escape(tag),
      "</td></tr></table></td></tr>"
    ]
  end

  defp footer(kind) do
    lines =
      Enum.map(footer_lines(kind), fn segments ->
        [~s(<p style="margin: 0 0 8px;">), Enum.map(segments, &html_segment/1), "</p>"]
      end)

    [
      ~s(<tr><td class="sf-pad" bgcolor="#{@panel}" style="background-color: #{@panel}; padding: 24px 40px 16px; border-radius: 0 0 18px 18px; font-family: #{@text}; font-size: 12px; line-height: 1.6; color: #{@muted};">),
      lines,
      "</td></tr>"
    ]
  end

  defp footer_lines({:member, preferences_url, unsubscribe_url}) do
    [
      [
        "You get this because you’re a SimpleFit member. ",
        {:link, "Email preferences", preferences_url, :footer},
        " · ",
        {:link, "Unsubscribe", unsubscribe_url, :footer}
      ],
      [@address]
    ]
  end

  defp footer_lines(kind), do: [[Map.fetch!(@footer_notes, kind)], [@address]]

  defp html_block({:panel, blocks}), do: html_block({:panel, blocks, :stone})

  defp html_block({:panel, blocks, style}) do
    {background, border} = panel_style(style)

    spaced([
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>),
      ~s(<td bgcolor="#{background}" style="background-color: #{background}; #{border}border-radius: 16px; padding: 18px 20px 8px;">),
      blocks |> visible() |> Enum.map(&panel_spaced(content(&1))),
      "</td></tr></table>"
    ])
  end

  defp html_block(block), do: spaced(content(block))

  defp content({:eyebrow, text}), do: mono_line(text, @olive)
  defp content({:eyebrow, text, :danger}), do: mono_line(text, @danger)
  defp content({:label, text}), do: mono_line(text, @olive)
  defp content({:heading, text}), do: content({:heading, text, 26})

  defp content({:heading, text, size}) do
    [
      ~s(<h1 style="margin: 0; font-family: #{@display}; font-size: #{size}px; font-weight: 600; letter-spacing: -0.02em; line-height: 1.2; color: #{@ink};">),
      escape(text),
      "</h1>"
    ]
  end

  defp content({:paragraph, segments}), do: paragraph(segments, "15px", @body, 400)
  defp content({:paragraph, segments, :small}), do: paragraph(segments, "14px", @body, 400)
  defp content({:paragraph, segments, :note}), do: paragraph(segments, "13px", @muted, 400)
  defp content({:paragraph, segments, :lead}), do: paragraph(segments, "14px", @ink, 700)

  defp content({:button, label, url, variant}) do
    {background, color, border} = button_style(variant)

    [
      ~s(<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>),
      ~s(<td bgcolor="#{background}" style="background-color: #{background}; border-radius: 14px; #{border}">),
      ~s(<a href="),
      escape(url),
      ~s(" target="_blank" style="display: inline-block; padding: 15px 26px; font-family: #{@text}; font-size: 15px; font-weight: 800; line-height: 1.2; color: #{color}; text-decoration: none; border-radius: 14px;">),
      escape(label),
      "</a></td></tr></table>"
    ]
  end

  defp content({:code, code, size, align}) do
    [
      ~s(<p style="margin: 0; font-family: #{@display}; font-size: #{size}px; font-weight: 700; letter-spacing: 0.16em; line-height: 1.2; color: #{@ink}; text-align: #{align};">),
      escape(code),
      "</p>"
    ]
  end

  defp content({:caption, text, align}) do
    [
      ~s(<p style="margin: 0; font-family: #{@text}; font-size: 13px; line-height: 1.6; color: #{@muted}; text-align: #{align};">),
      escape(text),
      "</p>"
    ]
  end

  defp content({:display, text}) do
    [
      ~s(<p style="margin: 0; font-family: #{@display}; font-size: 34px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.15; color: #{@ink};">),
      escape(text),
      "</p>"
    ]
  end

  defp content({:mono, text}) do
    [
      ~s(<p style="margin: 0; font-family: #{@mono}; font-size: 18px; font-weight: 600; line-height: 1.4; color: #{@ink}; word-break: break-all;">),
      escape(text),
      "</p>"
    ]
  end

  defp content({:bullets, items, marker}) do
    {glyph, marker_color} = bullet_marker(marker)

    [
      ~s(<table role="presentation" cellpadding="0" cellspacing="0" border="0">),
      Enum.map(items, fn item ->
        [
          ~s(<tr><td valign="top" style="padding: 0 10px 8px 0; font-family: #{@text}; font-size: 14px; line-height: 1.5; font-weight: 800; color: #{marker_color};">#{glyph}</td>),
          ~s(<td valign="top" style="padding: 0 0 8px; font-family: #{@text}; font-size: 14px; line-height: 1.5; color: #{@body};">),
          escape(item),
          "</td></tr>"
        ]
      end),
      "</table>"
    ]
  end

  defp content({:rows, rows}) do
    rows = visible(rows)
    last = length(rows) - 1

    [
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">),
      rows
      |> Enum.with_index()
      |> Enum.map(fn {{label, value}, index} ->
        rule = if index < last, do: "border-bottom: 1px solid #{@rule};", else: ""

        [
          ~s(<tr><td valign="top" style="padding: 10px 16px 10px 0; #{rule} font-family: #{@text}; font-size: 14px; color: #{@muted};">),
          escape(label),
          ~s(</td><td valign="top" align="right" style="padding: 10px 0; #{rule} font-family: #{@text}; font-size: 14px; font-weight: 700; color: #{@ink}; text-align: right;">),
          escape(value),
          "</td></tr>"
        ]
      end),
      "</table>"
    ]
  end

  defp content({:steps, steps}) do
    [
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">),
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {{title, detail}, number} ->
        detail_line =
          if detail,
            do: [
              ~s(<p style="margin: 2px 0 0; font-family: #{@text}; font-size: 13px; line-height: 1.5; color: #{@muted};">),
              escape(detail),
              "</p>"
            ],
            else: []

        [
          ~s(<tr><td valign="top" width="42" style="width: 42px; padding: 0 0 14px;">),
          ~s(<div style="width: 24px; height: 24px; border: 2px solid #{@outline}; border-radius: 14px; font-family: #{@text}; font-size: 13px; font-weight: 800; line-height: 24px; text-align: center; color: #{@olive};">#{number}</div></td>),
          ~s(<td valign="top" style="padding: 0 0 14px;">),
          ~s(<p style="margin: 0; font-family: #{@text}; font-size: 15px; font-weight: 700; line-height: 1.4; color: #{@ink};">),
          escape(title),
          "</p>",
          detail_line,
          "</td></tr>"
        ]
      end),
      "</table>"
    ]
  end

  defp content({:progress, completed, total}) do
    segments =
      1..total
      |> Enum.map(fn segment ->
        color = if segment <= completed, do: @progress_done, else: @progress_todo

        ~s(<td height="6" bgcolor="#{color}" style="height: 6px; background-color: #{color}; border-radius: 3px; font-size: 0; line-height: 0;">&nbsp;</td>)
      end)
      |> Enum.intersperse(
        ~s(<td width="4" style="width: 4px; font-size: 0; line-height: 0;">&nbsp;</td>)
      )

    [
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" aria-label="#{completed} of #{total} done"><tr>),
      segments,
      "</tr></table>"
    ]
  end

  defp content({:stats, stats}) do
    tiles =
      stats
      |> Enum.map(fn {value, label} ->
        [
          ~s(<td valign="top" bgcolor="#{@panel}" style="background-color: #{@panel}; border-radius: 14px; padding: 14px;">),
          ~s(<p style="margin: 0; font-family: #{@display}; font-size: 26px; font-weight: 700; line-height: 1.2; color: #{@ink};">),
          escape(value),
          ~s(</p><p style="margin: 4px 0 0; font-family: #{@mono}; font-size: 10px; letter-spacing: 0.1em; color: #{@muted};">),
          escape(label),
          "</p></td>"
        ]
      end)
      |> Enum.intersperse(~s(<td width="10" style="width: 10px;"></td>))

    [
      ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>),
      tiles,
      "</tr></table>"
    ]
  end

  defp content({:identity, initials, eyebrow, name, detail}) do
    avatar =
      if initials,
        do: [
          ~s(<td valign="middle" width="70" style="width: 70px;">),
          ~s(<div style="width: 56px; height: 56px; border-radius: 28px; background-color: #{@avatar}; font-family: #{@display}; font-size: 16px; font-weight: 700; line-height: 56px; text-align: center; color: #{@avatar_text};">),
          escape(initials),
          "</div></td>"
        ],
        else: []

    detail_line =
      if detail,
        do: [
          ~s(<p style="margin: 2px 0 0; font-family: #{@text}; font-size: 13px; line-height: 1.5; color: #{@muted};">),
          escape(detail),
          "</p>"
        ],
        else: []

    [
      ~s(<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>),
      avatar,
      ~s(<td valign="middle">),
      mono_line(eyebrow, @olive),
      ~s(<p style="margin: 2px 0 0; font-family: #{@display}; font-size: 18px; font-weight: 600; line-height: 1.3; color: #{@ink};">),
      escape(name),
      "</p>",
      detail_line,
      "</td></tr></table>"
    ]
  end

  defp paragraph(segments, size, color, weight) do
    [
      ~s(<p style="margin: 0; font-family: #{@text}; font-size: #{size}; font-weight: #{weight}; line-height: 1.6; color: #{color};">),
      Enum.map(segments, &html_segment/1),
      "</p>"
    ]
  end

  defp html_segment({:strong, text}),
    do: [~s(<strong style="color: #{@ink};">), escape(text), "</strong>"]

  defp html_segment({:link, label, url}), do: link(label, url, @olive, 800, "underline")
  defp html_segment({:link, label, url, :danger}), do: link(label, url, @danger, 800, "underline")
  defp html_segment({:link, label, url, :footer}), do: link(label, url, @olive, 700, "none")
  defp html_segment(text) when is_binary(text), do: escape(text)

  defp link(label, url, color, weight, decoration) do
    [
      ~s(<a href="),
      escape(url),
      ~s(" target="_blank" style="color: #{color}; font-weight: #{weight}; text-decoration: #{decoration};">),
      escape(label),
      "</a>"
    ]
  end

  defp button_style(:dark), do: {@bar, @cta_text, ""}
  defp button_style(:olive), do: {@olive_button, @bar, ""}
  defp button_style(:outline), do: {@card, @ink, "border: 1.5px solid #{@outline};"}

  defp button_style(:danger),
    do: {@danger_button, @danger, "border: 1.5px solid #{@danger_border};"}

  defp panel_style(:stone), do: {@panel, ""}
  defp panel_style(:highlight), do: {@highlight, ""}
  defp panel_style(:quiet), do: {@quiet_panel, "border: 1px solid #{@rule}; "}

  defp bullet_marker(:olive), do: {"•", @olive}
  defp bullet_marker(:muted), do: {"•", @olive_soft}
  defp bullet_marker(:check), do: {"✓", @olive}
  defp bullet_marker(:dash), do: {"–", @danger}

  defp mono_line(text, color) do
    [
      ~s(<p style="margin: 0; font-family: #{@mono}; font-size: 11px; letter-spacing: 0.16em; color: #{color};">),
      escape(text),
      "</p>"
    ]
  end

  # Vertical rhythm of the design (18 px between body blocks, 10 px in panels).
  defp spaced(content),
    do: [~s(<div style="margin: 0 0 18px;">), content, "</div>"]

  defp panel_spaced(content),
    do: [~s(<div style="margin: 0 0 10px;">), content, "</div>"]

  defp escape(text) when is_binary(text), do: Plug.HTML.html_escape(text)

  defp visible(items), do: Enum.reject(items, &is_nil/1)

  ## Plain text

  @doc "The plain-text part: the same message, readable without HTML."
  @spec text(frame(), [block()]) :: String.t()
  def text(frame, blocks) do
    body =
      blocks
      |> visible()
      |> Enum.map(&text_block/1)
      |> visible()
      |> Enum.join("\n\n")

    footer = Enum.map_join(footer_lines(frame.footer), "\n", &text_segments/1)

    "SimpleFit · #{frame.tag}\n\n" <> body <> "\n\n--\n" <> footer <> "\n"
  end

  defp text_block({:eyebrow, text}), do: text
  defp text_block({:eyebrow, text, _tone}), do: text
  defp text_block({:heading, text}), do: text_block({:heading, text, 26})

  defp text_block({:heading, text, _size}),
    do: text <> "\n" <> String.duplicate("=", String.length(text))

  defp text_block({:paragraph, segments}), do: text_segments(segments)
  defp text_block({:paragraph, segments, _size}), do: text_segments(segments)
  defp text_block({:button, label, url, _variant}), do: "#{label}:\n#{url}"

  defp text_block({:panel, blocks}),
    do: blocks |> visible() |> Enum.map(&text_block/1) |> visible() |> Enum.join("\n")

  defp text_block({:panel, blocks, _style}), do: text_block({:panel, blocks})
  defp text_block({:label, text}), do: text
  defp text_block({:code, code, _size, _align}), do: "    " <> code
  defp text_block({:caption, text, _align}), do: text
  defp text_block({:display, text}), do: text
  defp text_block({:mono, text}), do: text

  defp text_block({:bullets, items, marker}) do
    prefix =
      case marker do
        :check -> "✓ "
        :dash -> "– "
        _dot -> "- "
      end

    Enum.map_join(items, "\n", &(prefix <> &1))
  end

  defp text_block({:rows, rows}),
    do: rows |> visible() |> Enum.map_join("\n", fn {l, v} -> "#{l}: #{v}" end)

  # The eyebrow carries the progress in words.
  defp text_block({:progress, _completed, _total}), do: nil

  defp text_block({:steps, steps}) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn
      {{title, nil}, number} -> "#{number}. #{title}"
      {{title, detail}, number} -> "#{number}. #{title}\n   #{detail}"
    end)
  end

  defp text_block({:stats, stats}),
    do: Enum.map_join(stats, " · ", fn {value, label} -> "#{value} #{String.downcase(label)}" end)

  defp text_block({:identity, _initials, eyebrow, name, detail}),
    do: Enum.join(Enum.reject([eyebrow, name, detail], &is_nil/1), "\n")

  defp text_segments(segments) do
    Enum.map_join(segments, fn
      {:strong, text} -> text
      {:link, label, url} -> "#{label} (#{url})"
      {:link, label, url, _style} -> "#{label} (#{url})"
      text -> text
    end)
  end
end
