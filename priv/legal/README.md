# Legal document registry (production)

Read at boot by `SimpleFit.Legal.Registry` (ADR 0022). **Empty: no legal
text is approved yet** (SF-71: product policy approved, legal approval
pending), so Coach–Fighter sharing cannot be ready in any environment.

Publishing an approved version (Part B) is a reviewed code change:

1. Put the approved texts, exactly as approved, in
   `documents/<document_id>/<version>/<language>/{title,summary,checkbox,full}.md`
   (UTF-8 Markdown subset: `#`/`##`/`###` headings, paragraphs, `-` lists).
2. Run `mix legal.hash documents/<document_id>/<version>/<language>` for
   every language and copy each hash into `registry.json`.
3. Add the version to `registry.json` with its real `approval_ref`,
   `approved_by`, `effective_at` and `published_at`, and mark the version it
   replaces `superseded`.
4. Only then may an environment name it in `COACHING_DISCLOSURES` /
   `COACHING_DATA_RULES_VERSION`.

Never edit an approved text in place: a changed text is a new version (or,
for a non-material fix approved as such, a new hash recorded with its
approval). Test fixtures (`test_only`) never belong here; this directory
refuses them.
