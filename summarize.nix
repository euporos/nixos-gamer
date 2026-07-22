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
#     "num_ctx":    8192,                        # optional override
#     "temperature": 0.3,                        # optional override
#     "keep_alive": 0                            # optional; 0 = unload model right
#                                                #   after (frees VRAM for whisper)
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
#           {"error": "..."}                          (4xx/5xx)
#
# VRAM caveat (11 GB, shared with whisper): the Qwen3-14B weights are ~9 GB, and
# a whisper job also needs the card. keep_alive defaults to 0 so the model
# unloads immediately after each summary — this keeps the collision window tiny
# but does not fully eliminate it (a summary running exactly when the 10-min
# whisper sweep fires could still contend). Real mutual exclusion between the
# two GPU users is left for when this gets wired into the UI/automation.

let
  # Pure-stdlib HTTP server: builds the prompt, calls Ollama /api/chat, returns
  # the summary. Reads its config from the environment (set in the unit below).
  server = pkgs.writeText "whisper-summarize.py" ''
    import json, os, re, sys, urllib.request, urllib.error
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    OLLAMA       = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    MODEL        = os.environ.get("SUMMARIZE_MODEL", "qwen3:14b")
    ROOT         = os.path.realpath(os.environ.get("TRANSCRIPT_ROOT", "/srv/whisper/transcripts"))
    NUM_CTX      = int(os.environ.get("SUMMARIZE_NUM_CTX", "8192"))
    TEMPERATURE  = float(os.environ.get("SUMMARIZE_TEMPERATURE", "0.3"))
    KEEP_ALIVE   = os.environ.get("SUMMARIZE_KEEP_ALIVE", "0")
    PORT         = int(os.environ.get("SUMMARIZE_PORT", "8991"))

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

    def summarize(req):
        text = req.get("text")
        fpath = req.get("file") or req.get("path")
        if (not text or not text.strip()) and fpath:
            with open(resolve_file(fpath), encoding="utf-8", errors="replace") as f:
                text = f.read()
        if not text or not text.strip():
            raise ValueError("no transcript: provide 'text' or 'file'")

        payload = {
            "model": req.get("model") or MODEL,
            "messages": build_messages(text, req.get("prompt") or "", req.get("language")),
            "stream": False,
            "think": False,  # Qwen3 is a thinking model; disable for clean, fast summaries
            "keep_alive": req.get("keep_alive", KEEP_ALIVE),
            "options": {
                "temperature": float(req.get("temperature", TEMPERATURE)),
                "num_ctx": int(req.get("num_ctx", NUM_CTX)),
            },
        }
        data = json.dumps(payload).encode("utf-8")
        r = urllib.request.Request(OLLAMA + "/api/chat", data=data,
                                   headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=1800) as resp:
            out = json.load(resp)
        summary = THINK_RE.sub("", out["message"]["content"]).strip()
        return {"summary": summary, "model": payload["model"]}

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
      SUMMARIZE_NUM_CTX = "8192";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${server}";
      Restart = "on-failure";
      RestartSec = 2;
      # Least privilege: no dedicated user needed. Read access to the transcript
      # dir comes from the whisper group (files there are group/world readable).
      DynamicUser = true;
      SupplementaryGroups = [ "whisper" ];
      # Talks only to localhost:11434 and reads only transcripts — lock it down.
      ProtectSystem = "strict";
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
