# Named summarization prompt presets.
#
# Each attribute is a reusable prompt for the summarizer, offered as a pick-able
# preset in the whisper web UI's summarize controls: choosing a name drops its
# text into that transcript's prompt box, which is then sent verbatim as the job
# spec's free-text "prompt" (the instruction applied in the FINAL render pass;
# see summarize.nix). Nothing here changes the worker — a preset is just prompt
# text keyed by a friendly name.
#
# Add a preset by adding an attribute: the attribute name is the label shown in
# the dropdown, the value is the prompt prose (use a '' … '' multi-line string).
# Redeploy (`nix run .#deploy`) to publish — whisper.nix renders this attrset to
# /prompts.json, which the UI fetches on load.
#
# Because the preset is applied at render time over the whole transcript (or, for
# long transcripts, over the purpose-neutral condensed notes), write it as a
# purpose/focus instruction, not a per-chunk rule.
{
  diary = ''
    Focus on personal and philosophical utterings, specifically around family,
    relationships and sexuality. Skip anything really mundane like everyday
    events unless they serve to illustrate any of the aforementioned topics.
  '';
}
