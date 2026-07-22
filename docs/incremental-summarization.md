# Incremental (chunked) summarization — design of record

Status: **design agreed, not yet implemented.** This doc is the spec for a fresh
build session. No code here on purpose.

## Problem

The summarizer feeds a whole transcript to Qwen3 in one Ollama call. `num_ctx`
(16k, VRAM-capped — see the "context window" note in `CLAUDE.md`) bounds the
*input+output*; when a transcript exceeds it, Ollama silently drops the **oldest**
tokens, so long recordings get a summary that quietly ignores their start. We
exceed 16k often enough that this needs a real fix: summarize the *whole*
transcript without ever putting more than fits into a single call.

## Shape of the solution

Two orthogonal changes:

1. **Transport → fully async, file-driven, exactly like the whisper pipeline.**
   Retire the synchronous HTTP endpoint + its daemon. A summary becomes a job you
   drop in an inbox and poll for, and the result is a file you link to (no inline
   result — a link like the transcript files is sufficient). The summary worker
   is a second GPU-lock holder beside `whisper-worker`.
2. **Long transcripts → chunked condense with carry-over**, entirely inside the
   worker (invisible to transport/UI). Optionally cache the condensed notes so
   repeat prompts on the same transcript stay cheap.

Rationale for full-async over a sync/async hybrid: the box's whole design is
drop-and-poll; result delivery + "it's done" is **already built** (the UI polls
`/status/transcripts/` and renders `<stem>.summary*.md` as it appears). Going
fully async *removes* mechanisms (no HTTP daemon, no nginx proxy location, no
sync/async branch, no 503-on-busy) and reuses a worker pattern we already run.

## Locked decisions

- **Single user** — job↔transcript attribution for in-flight jobs is kept in the
  browser's `localStorage` (like existing per-file `meta`/prompts). A second
  browser wouldn't know an in-flight job's transcript; the finished file is fully
  shared regardless. Accepted.
- **Show `<stem>.notes.md`** — the condensed-notes cache is surfaced as a link in
  the archive, not hidden.
- **Progress: queued/running first** — ship an indeterminate "running" state
  (like whisper before its ETA bar); add `chunk k/n` progress later.
- **Mid-run cancel is best-effort** — cancelling a *queued* job removes its spec;
  a *running* job is aborted between chunk passes when the worker sees the
  sentinel. Aborting an in-flight Ollama generation is not attempted.

## On-disk layout

New job dirs parallel to the audio inbox (tmpfiles-created):

| path | mode | purpose |
|------|------|---------|
| `/srv/whisper/summaries/inbox/`   | `2770 whisper whisper` | queued job specs (JSON); nginx (whisper group) PUTs here |
| `/srv/whisper/summaries/work/`    | `0770 whisper whisper` | the spec being processed = the "running" signal |
| `/srv/whisper/summaries/failed/`  | `0770 whisper whisper` | errored jobs (spec kept for inspection/requeue) |
| `/srv/whisper/summaries/control/` | `2770 whisper whisper` | `<jobid>.cancel` sentinels |

**Outputs stay in `/srv/whisper/transcripts/`** — `<stem>.summary.N.md` (existing
race-free `O_EXCL` numbering) and, for chunked jobs, `<stem>.notes.md`. This keeps
the existing archive grouping, UI polling, and NAS delivery working unchanged.

## Job spec (the one genuinely new artifact)

A small JSON file (the prompt is free-form text, so it can't live in a filename):

```json
{
  "stem":        "<transcript stem>",
  "prompt":      "<extra instructions>",
  "language":    "de|en|fr|ru",
  "model":       "qwen3:14b",
  "num_ctx":     16384,
  "temperature": 0.3,
  "label":       "action items"
}
```

- `stem` required; the worker reads `<stem>.speakers.txt` (preferred) else
  `<stem>.txt` from `transcripts/`, with the same path-safety as today's `file`
  (must canonicalize to a direct child of the transcript dir).
- Everything else optional; overrides the env defaults.
- **Filename** = a UI-generated job id. The stem is inside the spec (worker needs
  it) and in the UI's `localStorage` `jobid → {stem, label}` map (for attribution).

## Intake / status / control (nginx — same verbs already used)

- **Submit**: `PUT /summaries/<jobid>.json` → `summaries/inbox/` (WebDAV PUT,
  `limit_except PUT`), atomic temp+rename. Specs are tiny → no "wait until stable".
- **Poll**: add `/status/summaries/inbox|work|failed/` autoindex-JSON listings.
- **Cancel**: `PUT /summaries/control/<jobid>.cancel`.
- **Retire**: the `= /summarize` proxy location.
- Add `summaries/inbox` + `summaries/control` to nginx `ReadWritePaths`.

## systemd

- **Add** `summarize-worker.service` (oneshot) + `.path`
  (`DirectoryNotEmpty=/srv/whisper/summaries/inbox`) + a sweep timer — a copy of
  the `whisper-worker` trio.
- **Add** `summarize-control.service` + `.path` (`summaries/control`) — mirrors
  `whisper-control`.
- **Remove** `whisper-summarize.service` (HTTP daemon) and with it `SUMMARIZE_PORT`
  and the `LOCK_TIMEOUT`/`Busy`/503 path — a queued job simply *waits* on the
  flock like `whisper-worker` does; there is no caller to time out.
- **Worker runs as root**, like `whisper-worker`. This drops the `DynamicUser`
  read-only-filesystem workaround the old daemon needed (`ReadWritePaths` +
  loosened CIFS perms); root already owns the whisper worker, so this is the
  consistent, simpler choice. (The loosened CIFS `dir_mode/file_mode` in
  `configuration.nix` can stay or be reverted once the DynamicUser is gone —
  root bypasses those masks anyway.)
- Ollama service + env (`OLLAMA_KEEP_ALIVE=0`, `OLLAMA_FLASH_ATTENTION=1`,
  `OLLAMA_KV_CACHE_TYPE=q8_0`) stay as-is.

## Worker algorithm (chunking lives here, invisible to everything else)

Serial, one job at a time:

1. Parse spec; resolve transcript source (`.speakers.txt` else `.txt`).
2. Move spec `inbox/ → work/` (this *is* the running signal the UI polls).
3. Estimate tokens (~4 chars/token, conservative).
4. `flock /run/whisper-gpu.lock` — **held for the whole job**.
5. Branch:
   - **Fits one pass** (est ≤ ~0.8·`num_ctx`) → single Ollama call, `keep_alive=0`.
   - **Too big** → chunked condense (see below), producing (and caching)
     `<stem>.notes.md`, then a final render pass applying the user's prompt to the
     notes. Force unload (`keep_alive=0` on the last call) + poll `/api/ps`
     **before** releasing the lock.
6. Release lock.
7. Write `<stem>.summary.N.md` into `transcripts/` (existing `O_EXCL` numbering);
   best-effort NAS copy in a background thread (existing logic).
8. Move spec out of `work/`; on any error move it to `failed/`.
9. Between chunk passes, check for `<jobid>.cancel` and bail if present.

### Chunked condense

- **Chunk on transcript structure, never mid-segment.** `.speakers.txt` lines are
  `[mm:ss] SPEAKER: text`; `.txt` is one segment per line. Break on line /
  speaker-turn boundaries.
- **Sizing.** Per-call budget ≈ `num_ctx − (running-notes reserve ~1.5k +
  output reserve ~1.5k + system/instructions ~0.8k)` ≈ **~12k tokens of fresh
  transcript per chunk (~1 h of speech)**. So a 3 h recording is ~3 passes.
- **v1 strategy: refine (rolling carry-over).** Maintain a **bounded, structured**
  running-notes doc (capped bullet list of facts/decisions/figures/names); each
  pass gets *(notes so far + next chunk)* → *(updated notes)*. Optionally carry
  the raw last ~300 tokens verbatim so a sentence split across a boundary isn't
  lost. *Alternative if drift is a problem: map each chunk → notes independently,
  then one reduce/merge pass. Single GPU serializes either way, so refine's
  sequential nature costs nothing here.*
- **Condense uses a neutral, comprehensive instruction** ("capture everything
  faithfully"), NOT the user's purpose-prompt. The purpose-prompt is applied only
  in the final render pass over the notes — otherwise "list action items" applied
  per chunk would discard context later chunks need.
- **Keep the model warm across passes.** The old per-request `keep_alive=0` would
  reload ~9 GB every chunk. Under the single held GPU lock it is safe to run the
  chunk loop with `keep_alive` non-zero and only force the unload at the very end.
  This is the key reason chunking and the GPU lock are co-designed.

### Notes cache (makes "many prompts per transcript" cheap)

`<stem>.notes.md` is the condensed, purpose-neutral digest. A later job for the
same stem whose transcript is long **skips chunking** and does only the final
render pass over the cached notes — a fast single call. No API surface; a pure
internal shortcut. (Short transcripts never produce a notes file; their single
pass yields the summary directly.)

## UI changes (`whisper-ui/index.html`)

- **Submit**: the existing summarize button + prompt textarea now builds the JSON
  spec and `PUT`s it to `/summaries/<jobid>.json` instead of POSTing and awaiting.
  Remove the inline-result display and the 503 handling.
- **Poll**: add the three `/status/summaries/...` listings to `poll()`.
- **Render**: show in-flight summary jobs as chips on the matching transcript card
  ("summary · queued/running" + cancel), attributed via the `localStorage` map.
  Finished `<stem>.summary.N.md` and `<stem>.notes.md` render as links exactly as
  transcript files do now.
- **Cancel**: `PUT /summaries/control/<jobid>.cancel` (same shape as transcription
  cancel/requeue).
- The overflow token warning becomes informational ("long — will be condensed in
  chunks"), not a blocker.

## What gets retired

The long-running `whisper-summarize` HTTP daemon, the `= /summarize` nginx proxy
location, the sync/async decision, and the 503-on-GPU-busy behavior. Net: **fewer
moving parts than today**, one job pattern for everything the GPU does.

## Deferred / later

- `chunk k/n` progress surfaced to the UI (a progress marker file the UI lists).
- Requeue for failed summary jobs (mirror the transcription `.requeue` sentinel).
- Tuning: refine vs map+reduce, chunk/notes/tail sizes.

## Verification & deploy (repo conventions)

- `nix eval --raw .#nixosConfigurations.nixos-gamer.config.system.build.toplevel.drvPath`
  must succeed before deploy.
- Embedded Python (worker): extract the `writeText` block, `textwrap.dedent`, then
  `py_compile` — the store path can't be substituted, so don't realize it directly.
- Deploy with `nix run .#deploy` (builds ON the box); the box is off most of the
  time (WoL) — confirm it's awake first. Commit only when asked; don't push/deploy
  unprompted.
- Keep `CLAUDE.md` current (new summary worker + job dirs + retired daemon).
