{ config, pkgs, lib, ... }:

# Transcript summarization endpoint, served alongside the whisper UI.
#
#   POST http://192.168.85.30:8990/summarize
#
# Backed by a local Ollama running Qwen3 14B (GGUF, Q4) on the GTX 1080 Ti.
# Unlike the WhisperX (PyTorch) stack, this does NOT hit the Pascal wall:
# Ollama ships its own llama.cpp CUDA kernels, and we build ollama-cuda for
# sm_61 explicitly (see the cudaCapabilities note below) with CUDA 12.9, which
# still supports Pascal. No fp16 needed — the GGUF quant paths use integer math.
#
# Request (JSON body, Content-Type: application/json):
#   {
#     "text":       "<transcript text>",        # optional
#     "file":       "meeting.txt",               # optional: bare name resolved
#                                                #   under /srv/whisper/transcripts,
#                                                #   or an absolute path inside it
#     "prompt":     "<extra instructions>",      # optional: appended to the base
#                                                #   summarizer instructions
#     "language":   "de|en|fr|ru|...",           # optional: force output language
#                                                #   (default: same as transcript)
#     "model":      "qwen3:14b",                 # optional override
#     "num_ctx":    16384,                       # optional override (default 16384)
#     "temperature": 0.3,                        # optional override
#     "save":       "meeting"                    # optional: ALSO persist the
#                                                #   summary next to the transcript
#                                                #   as <stem>.summary[.N].md (stem
#                                                #   = a bare transcript name — same
#                                                #   path safety as "file", no
#                                                #   traversal). Numbered .2/.3/...
#                                                #   when earlier summaries exist,
#                                                #   and best-effort copied to the
#                                                #   NAS <stem>/ folder like the
#                                                #   transcripts. ("stem" alias ok)
#   }
# One of "text"/"file" is required. A raw (non-JSON) body is taken verbatim as
# the transcript, with extra instructions via the X-Summarize-Prompt header:
#   curl -sS --data-binary @meeting.txt \
#        -H 'X-Summarize-Prompt: In drei Stichpunkten.' \
#        http://192.168.85.30:8990/summarize
# Or by reference to an already-produced transcript:
#   curl -sS -H 'Content-Type: application/json' \
#        -d '{"file":"meeting.txt","prompt":"List action items only."}' \
#        http://192.168.85.30:8990/summarize
#
# Response: {"summary": "...", "model": "qwen3:14b"}  (HTTP 200)
#           + "file": "meeting.summary.md"   when "save" was given and persisted
#           + "save_error": "..."            when "save" was given but the write
#                                            failed (the summary is still returned)
#           {"error": "..."}                          (4xx/5xx)
#
# VRAM (11 GB, shared with whisper): the Qwen3-14B weights are ~9 GB, and a
# whisper job also needs the card, so the two are mutually excluded by a GPU
# lock — an flock() on /run/whisper-gpu.lock that the whisper worker also takes
# around each container run (whisper.nix). A summary holds the lock across the
# Ollama call AND until the model is confirmed unloaded (keep_alive is forced to
# 0 and /api/ps is polled), so whisper never starts while the LLM is resident,
# and vice versa. If a long transcription holds the GPU past LOCK_TIMEOUT (900s)
# the summary returns 503 rather than hanging. One card = the two genuinely
# serialize: a summary waits for an in-flight whisper job and vice versa.

let
  # Pure-stdlib HTTP server: builds the prompt, calls Ollama /api/chat, returns
  # the summary. Reads its config from the environment (set in the unit below).
  server = pkgs.writeText "whisper-summarize.py" ''
    import fcntl, json, os, re, sys, threading, time, urllib.request, urllib.error
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    OLLAMA       = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    MODEL        = os.environ.get("SUMMARIZE_MODEL", "qwen3:14b")
    ROOT         = os.path.realpath(os.environ.get("TRANSCRIPT_ROOT", "/srv/whisper/transcripts"))
    # Best-effort NAS delivery target (one folder per transcript), mirroring the
    # whisper worker. Automounted CIFS (may be offline) — delivery is fire-and-
    # forget in a background thread and never affects the response. Empty = off.
    NAS_ROOT     = os.environ.get("SUMMARIZE_NAS_ROOT", "")
    NUM_CTX      = int(os.environ.get("SUMMARIZE_NUM_CTX", "8192"))
    TEMPERATURE  = float(os.environ.get("SUMMARIZE_TEMPERATURE", "0.3"))
    PORT         = int(os.environ.get("SUMMARIZE_PORT", "8991"))
    # GPU mutex shared with the whisper worker (which flock()s the same file
    # around each container run). Created by tmpfiles as 0660 root:whisper; this
    # server runs in the whisper group and opens it read-only, which is enough
    # to take an exclusive flock on Linux.
    LOCK_PATH    = os.environ.get("GPU_LOCK", "/run/whisper-gpu.lock")
    LOCK_TIMEOUT = float(os.environ.get("SUMMARIZE_LOCK_TIMEOUT", "900"))

    class Busy(Exception):
        pass

    BASE_SYSTEM = (
        "You are a precise transcript summarizer. Summarize the transcript the "
        "user provides. Unless the user explicitly asks for another language, "
        "write the summary in the same language as the transcript. Be faithful: "
        "never invent facts, figures, names, dates, or decisions that are not in "
        "the transcript. Keep speaker attributions where they matter. Prefer "
        "clear structure (short paragraphs or bullet points)."
    )

    THINK_RE = re.compile(r"<think>.*?</think>\s*", re.DOTALL)

    def resolve_file(p):
        # Accept a bare name (resolved under ROOT) or an absolute path, but the
        # canonical target must stay inside ROOT — no traversal, no symlink-out.
        cand = p if os.path.isabs(p) else os.path.join(ROOT, p)
        cand = os.path.realpath(cand)
        if cand != ROOT and not cand.startswith(ROOT + os.sep):
            raise ValueError("file path is outside the transcript directory")
        if not os.path.isfile(cand):
            raise ValueError("no such transcript file")
        return cand

    def save_summary(stem, text):
        # Persist the summary next to the transcript as <stem>.summary[.N].md.
        # Same path safety as resolve_file: <stem> must be a bare name whose
        # target canonicalizes to a direct child of ROOT — no slashes, no
        # traversal, no symlink-out. Numbering is race-free (O_EXCL): the first
        # summary is <stem>.summary.md, the next free <stem>.summary.<N>.md.
        if os.path.basename(stem) != stem or stem in ("", ".", ".."):
            raise ValueError("invalid stem for save")
        for n in range(1, 1000):
            name = stem + ".summary.md" if n == 1 else "%s.summary.%d.md" % (stem, n)
            path = os.path.join(ROOT, name)
            if os.path.dirname(os.path.realpath(path)) != ROOT:
                raise ValueError("summary path is outside the transcript directory")
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o664)
            except FileExistsError:
                continue
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(text)
            except Exception:
                try:
                    os.unlink(path)  # don't leave an empty reserved file behind
                except OSError:
                    pass
                raise
            return name
        raise ValueError("too many summaries for this transcript")

    def deliver_nas(stem, name, text):
        # Copy the just-saved summary to the NAS <stem>/ folder, like the whisper
        # worker delivers transcripts. Best-effort: the share is an automounted
        # CIFS mount that may be offline (mkdir/write then just error out after
        # the mount timeout) — run in a daemon thread so the response is never
        # delayed, and swallow every error (the local copy is the source of
        # truth). Write to a .tmp then atomic-rename so a poller never sees a
        # half-written file.
        if not NAS_ROOT:
            return
        try:
            dest = os.path.join(NAS_ROOT, stem)
            os.makedirs(dest, exist_ok=True)
            tmp = os.path.join(dest, name + ".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, os.path.join(dest, name))
            sys.stderr.write("summarize: delivered %s -> %s/\n" % (name, dest))
        except Exception as e:  # noqa: BLE001 — best-effort, local copy is kept
            sys.stderr.write("summarize: NAS delivery of %s failed: %r\n" % (name, e))

    def build_messages(transcript, prompt, language):
        system = BASE_SYSTEM
        if language:
            system += " Write the summary in " + language + "."
        user = []
        if prompt and prompt.strip():
            user.append("Additional instructions:\n" + prompt.strip())
        user.append("Transcript:\n" + transcript)
        return [
            {"role": "system", "content": system},
            {"role": "user", "content": "\n\n".join(user)},
        ]

    def call_ollama(payload):
        data = json.dumps(payload).encode("utf-8")
        r = urllib.request.Request(OLLAMA + "/api/chat", data=data,
                                   headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=1800) as resp:
            return json.load(resp)

    def wait_unloaded(model, timeout=20.0):
        # keep_alive=0 makes Ollama evict the model right after generation, but
        # the VRAM free can lag the HTTP response slightly. Poll /api/ps until
        # the model is gone before releasing the GPU lock, so whisper never
        # starts a container while the ~9 GB LLM is still resident. Best-effort:
        # give up (release anyway) after `timeout` so a stuck ps never wedges us.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(OLLAMA + "/api/ps", timeout=5) as r:
                    loaded = json.load(r).get("models", [])
            except Exception:
                return
            names = set()
            for m in loaded:
                names.add(m.get("name"))
                names.add(m.get("model"))
            if model not in names:
                return
            time.sleep(0.5)

    def acquire_gpu_lock():
        # Exclusive flock, shared with the whisper worker. Poll non-blocking so
        # we can bound the wait: if a long transcription holds the GPU past
        # LOCK_TIMEOUT, fail fast with 503 rather than hang the request forever.
        fd = os.open(LOCK_PATH, os.O_RDONLY)
        start = time.monotonic()
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fd
            except OSError:
                if time.monotonic() - start > LOCK_TIMEOUT:
                    os.close(fd)
                    raise Busy("GPU busy with transcription; try again shortly")
                time.sleep(0.5)

    def summarize(req):
        text = req.get("text")
        fpath = req.get("file") or req.get("path")
        if (not text or not text.strip()) and fpath:
            with open(resolve_file(fpath), encoding="utf-8", errors="replace") as f:
                text = f.read()
        if not text or not text.strip():
            raise ValueError("no transcript: provide 'text' or 'file'")

        model = req.get("model") or MODEL
        payload = {
            "model": model,
            "messages": build_messages(text, req.get("prompt") or "", req.get("language")),
            "stream": False,
            "think": False,  # Qwen3 is a thinking model; disable for clean, fast summaries
            # Always 0: the GPU lock is only a true mutex if the model is
            # unloaded before we release it (see wait_unloaded). A warm model
            # left resident would let whisper collide with it on the next job.
            "keep_alive": 0,
            "options": {
                "temperature": float(req.get("temperature", TEMPERATURE)),
                "num_ctx": int(req.get("num_ctx", NUM_CTX)),
            },
        }

        lock_fd = acquire_gpu_lock()
        try:
            out = call_ollama(payload)
            wait_unloaded(model)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)

        summary = THINK_RE.sub("", out["message"]["content"]).strip()
        result = {"summary": summary, "model": model}

        # Optional persistence (lock already released — this is pure IO). "save"
        # or its alias "stem" is a bare transcript name; on any failure keep the
        # summary in the response so the client never loses it.
        stem = req.get("save") or req.get("stem")
        if isinstance(stem, str) and stem.strip():
            try:
                name = save_summary(stem.strip(), summary)
                result["file"] = name
                threading.Thread(target=deliver_nas,
                                 args=(stem.strip(), name, summary),
                                 daemon=True).start()
            except Exception as e:  # noqa: BLE001 — report, but don't drop the summary
                result["save_error"] = str(e)

        return result

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            try:
                n = int(self.headers.get("Content-Length", "0") or "0")
                raw = self.rfile.read(n) if n else b""
                if "application/json" in (self.headers.get("Content-Type", "")):
                    req = json.loads(raw or b"{}")
                else:
                    req = {"text": raw.decode("utf-8", "replace"),
                           "prompt": self.headers.get("X-Summarize-Prompt", "")}
                self._send(200, summarize(req))
            except ValueError as e:
                self._send(400, {"error": str(e)})
            except Busy as e:
                self._send(503, {"error": str(e)})
            except urllib.error.HTTPError as e:
                detail = e.read().decode("utf-8", "replace")
                self._send(502, {"error": "ollama error: " + detail})
            except urllib.error.URLError as e:
                self._send(503, {"error": "ollama unreachable: " + str(e.reason)})
            except Exception as e:  # noqa: BLE001 — report, keep serving
                self._send(500, {"error": repr(e)})

        def log_message(self, fmt, *a):
            sys.stderr.write("summarize: " + (fmt % a) + "\n")

    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
  '';
in
{
  # Build ollama's CUDA kernels for the GTX 1080 Ti (Pascal, sm_61). The default
  # cudaCapabilities in this nixpkgs is "7.5 8.0 ... 12.1" — it OMITS 6.1, so a
  # stock ollama-cuda would die with "no kernel image is available" on this
  # card, exactly like the torch >= 2.8 wheels (see CLAUDE.md). CUDA 12.9 (the
  # default here) still supports Pascal, so forcing 6.1 compiles working
  # kernels. Only ollama-cuda is CUDA-built in this config, so scoping the arch
  # list to just this GPU is correct and keeps the build small.
  nixpkgs.config.cudaCapabilities = [ "6.1" ];

  # Shared GPU mutex file. Root (whisper-worker) and the whisper group (this
  # summarizer, DynamicUser + SupplementaryGroups) both flock() it; 0660 lets
  # the group open it read-only, which suffices for an exclusive flock.
  systemd.tmpfiles.rules = [
    "f /run/whisper-gpu.lock 0660 root whisper -"
  ];

  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;   # explicit, so no global cudaSupport is needed
    host = "127.0.0.1";
    port = 11434;
    loadModels = [ "qwen3:14b" ]; # pulled by a separate oneshot after start
    environmentVariables = {
      # Unload models promptly — the 11 GB card is shared with whisper. Requests
      # may still override per-call via "keep_alive".
      OLLAMA_KEEP_ALIVE = "0";
      # Fit longer transcripts in a single pass. On the 11 GB card the ~9 GB Q4
      # weights leave only ~2 GB for the KV cache, and fp16 KV is ~0.16 MB/token
      # (Qwen3-14B: 40 layers, 8 GQA KV heads, head-dim 128) — so 16k ctx would
      # need ~2.6 GB and spill. Flash attention + q8_0 KV roughly halves that to
      # ~1.3 GB, making SUMMARIZE_NUM_CTX=16384 (~80 min of speech) comfortable.
      # q8_0 KV *requires* flash attention; the quality cost is negligible.
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_KV_CACHE_TYPE = "q8_0";
    };
  };

  systemd.services.whisper-summarize = {
    description = "Transcript summarization HTTP endpoint (Ollama/Qwen3)";
    after = [ "ollama.service" "network.target" ];
    wants = [ "ollama.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      OLLAMA_URL = "http://127.0.0.1:11434";
      SUMMARIZE_MODEL = "qwen3:14b";
      TRANSCRIPT_ROOT = "/srv/whisper/transcripts";
      SUMMARIZE_PORT = "8991";
      # ~80 min of speech in one pass; fits VRAM thanks to flash-attn + q8_0 KV
      # (see services.ollama.environmentVariables). Overridable per request.
      SUMMARIZE_NUM_CTX = "16384";
      GPU_LOCK = "/run/whisper-gpu.lock";
      SUMMARIZE_LOCK_TIMEOUT = "900";
      # Best-effort NAS delivery of saved summaries, one folder per transcript —
      # same target the whisper worker uses. The CIFS mount is loosened
      # (dir_mode/file_mode, configuration.nix) so this DynamicUser can write.
      SUMMARIZE_NAS_ROOT = "/media/NAS/Netspace/artifacts/transcriptions";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${server}";
      Restart = "on-failure";
      RestartSec = 2;
      # Least privilege: no dedicated user needed. Read access to the transcript
      # dir comes from the whisper group (files there are group/world readable);
      # the setgid transcripts dir (2775) makes summaries we create group-whisper
      # so nginx serves them.
      DynamicUser = true;
      SupplementaryGroups = [ "whisper" ];
      # NOT "strict": we write summaries under /srv/whisper/transcripts and copy
      # them to the automounted NAS under /media. "strict" would make both
      # read-only, and whitelisting the NAS via ReadWritePaths would force the
      # autofs mount at *service start* — hanging/failing when the NAS is offline,
      # exactly what the box's nofail+automount design avoids. "true" keeps /usr
      # and /boot read-only while leaving /srv and /media writable, and the NAS
      # still mounts lazily on first write.
      ProtectSystem = "true";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  # Expose the endpoint on the existing whisper vhost (defined in whisper.nix).
  # NixOS merges locations across modules; an exact-match location wins over the
  # "/" PUT-inbox catch-all, so uploads are unaffected.
  services.nginx.virtualHosts."whisper".locations."= /summarize" = {
    proxyPass = "http://127.0.0.1:8991";
    extraConfig = ''
      proxy_read_timeout 1800s;
      proxy_send_timeout 1800s;
      proxy_request_buffering off;
      limit_except POST { deny all; }
    '';
  };
}
