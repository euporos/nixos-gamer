{ config, pkgs, lib, ... }:

# Synchronous, OpenAI-compatible chat endpoint for interactive LAN clients
# (first user: the Emacs proofreader `tchecker` in ~/config), backed by the same
# Ollama/Qwen3 as the summarizer.
#
#   POST http://192.168.85.30:8990/v1/chat/completions
#        body = {"messages": [...], "temperature": 0.0}   (OpenAI shape)
#   200  -> {"choices": [{"message": {"role": "assistant", "content": "..."}}]}
#   503  -> GPU busy (a transcription or summary holds the lock) — the client is
#           expected to fall back to a hosted API, NOT to wait.
#
# Ollama itself stays on 127.0.0.1: it has no auth (anyone reaching it could
# pull/delete models) and, more importantly, a direct call would bypass the GPU
# lock. Loading ~9 GB next to a running WhisperX container OOMs one of them.
#
# GPU LOCK + WARM WINDOW: the proxy takes /run/whisper-gpu.lock NON-blocking
# (busy -> 503 immediately) and then KEEPS it, with the model loaded, for an idle
# window after each request. Back-to-back calls (proofreading paragraph after
# paragraph) thus skip the multi-second reload. When the window passes without a
# request it unloads the model, waits until the VRAM is actually free, and only
# then releases the lock — so a whisper job queued meanwhile waits at most one
# window and never starts next to the resident LLM. Holding the lock is what
# makes the warm model safe; the two are inseparable.
#
# The request's "model" is ignored: the proxy always uses LLM_PROXY_MODEL (the
# summarizer's model — the only one pulled, and the only one sized for the card).
let
  proxyPy = pkgs.writeText "llm-proxy.py" ''
    import fcntl, json, os, re, signal, sys, time, urllib.error, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer

    OLLAMA    = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    MODEL     = os.environ.get("LLM_PROXY_MODEL", "qwen3:14b")
    LOCK_PATH = os.environ.get("GPU_LOCK", "/run/whisper-gpu.lock")
    PORT      = int(os.environ.get("LLM_PROXY_PORT", "11435"))
    IDLE_SECS = int(os.environ.get("LLM_PROXY_IDLE_SECS", "180"))
    NUM_CTX   = int(os.environ.get("LLM_PROXY_NUM_CTX", "8192"))
    # Ollama's own keep_alive outlives our window, so normally WE unload; it is
    # only the safety net if this process dies without running its cleanup.
    KEEP_ALIVE = str(IDLE_SECS + 120) + "s"
    THINK_RE  = re.compile(r"<think>.*?</think>\s*", re.DOTALL)

    lock_fd = None      # held GPU lock (fd), or None
    last_use = 0.0      # monotonic time of the last finished request

    def log(*a):
        print(*a, file=sys.stderr, flush=True)

    def try_lock():
        global lock_fd
        if lock_fd is not None:
            return True
        fd = os.open(LOCK_PATH, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
        lock_fd = fd
        log("gpu lock acquired")
        return True

    def ollama_post(path, payload, timeout):
        r = urllib.request.Request(OLLAMA + path, data=json.dumps(payload).encode("utf-8"),
                                   headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return json.load(resp)

    def wait_unloaded(timeout=30.0):
        # Same as summarize.nix: the VRAM free can lag the unload response.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(OLLAMA + "/api/ps", timeout=5) as r:
                    loaded = json.load(r).get("models", [])
            except Exception:
                return
            if not any(MODEL in (m.get("name"), m.get("model")) for m in loaded):
                return
            time.sleep(0.5)

    def release():
        global lock_fd
        if lock_fd is None:
            return
        try:
            ollama_post("/api/generate", {"model": MODEL, "keep_alive": 0}, 30)
        except Exception as e:
            log("unload failed:", e)
        wait_unloaded()
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)
            lock_fd = None
        log("model unloaded, gpu lock released")

    def chat(req):
        messages = req.get("messages")
        if not isinstance(messages, list) or not messages:
            raise ValueError("messages must be a non-empty list")
        payload = {
            "model": MODEL,
            "messages": messages,
            "stream": False,
            "think": False,  # Qwen3 is a thinking model; off for clean, fast output
            "keep_alive": KEEP_ALIVE,
            "options": {"temperature": float(req.get("temperature", 0.0)),
                        "num_ctx": NUM_CTX},
        }
        out = ollama_post("/api/chat", payload, 900)
        if out.get("error"):
            raise RuntimeError("ollama: " + str(out["error"]))
        return THINK_RE.sub("", (out.get("message") or {}).get("content", "")).strip()

    class Handler(BaseHTTPRequestHandler):
        def send_json(self, status, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass  # client gave up (Emacs C-g) — nothing to tell it

        def error(self, status, typ, msg):
            self.send_json(status, {"error": {"type": typ, "message": msg}})

        def do_POST(self):
            global last_use
            if self.path != "/v1/chat/completions":
                return self.error(404, "not_found", self.path)
            try:
                n = int(self.headers.get("Content-Length", "0"))
                req = json.loads(self.rfile.read(n) or b"{}")
            except Exception as e:
                return self.error(400, "bad_request", str(e))
            if not try_lock():
                return self.error(503, "gpu_busy", "GPU busy (transcription or summary running)")
            try:
                t0 = time.monotonic()
                content = chat(req)
                log("chat ok: %d chars in, %d out, %.1fs" % (
                    sum(len(str(m.get("content", ""))) for m in req["messages"]),
                    len(content), time.monotonic() - t0))
            except ValueError as e:
                return self.error(400, "bad_request", str(e))
            except Exception as e:
                log("chat failed:", e)
                return self.error(502, "upstream_error", str(e))
            finally:
                last_use = time.monotonic()
            self.send_json(200, {
                "object": "chat.completion",
                "model": MODEL,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": content}}],
            })

        def log_message(self, fmt, *args):
            pass  # access log is nginx's job

    def on_term(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, on_term)
    # Single-threaded on purpose: requests serialize, and the idle check below
    # runs between them — no threads touching the lock.
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    server.timeout = 5
    log("listening on 127.0.0.1:%d, model %s, idle window %ds" % (PORT, MODEL, IDLE_SECS))
    try:
        while True:
            server.handle_request()
            if lock_fd is not None and time.monotonic() - last_use > IDLE_SECS:
                release()
    finally:
        # Stop/restart: never leave the model resident without the lock held.
        release()
  '';
in
{
  systemd.services.llm-proxy = {
    description = "GPU-lock-aware OpenAI-compatible chat proxy to Ollama";
    wantedBy = [ "multi-user.target" ];
    after = [ "ollama.service" "network.target" ];
    wants = [ "ollama.service" ];
    environment = {
      OLLAMA_URL = "http://127.0.0.1:11434";
      LLM_PROXY_MODEL = "qwen3:14b";
      LLM_PROXY_PORT = "11435";
      # Warm window: how long the model (and the GPU lock) is kept after the
      # last request. Also the worst-case extra wait for a queued transcription.
      LLM_PROXY_IDLE_SECS = "180";
      # Interactive text, not transcripts: ~10k chars in + the same out fits
      # comfortably, and the smaller KV cache loads faster than the 16k one.
      LLM_PROXY_NUM_CTX = "8192";
      GPU_LOCK = "/run/whisper-gpu.lock";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${proxyPy}";
      Restart = "on-failure";
      # Unload + VRAM wait on stop can take a few seconds.
      TimeoutStopSec = "60s";
      DynamicUser = true;
      # The lock file is 0660 root:whisper (summarize.nix tmpfiles).
      SupplementaryGroups = [ "whisper" ];
    };
  };

  # Exact-match, so it never shadows the PUT-only audio inbox at "/" (whisper.nix).
  services.nginx.virtualHosts."whisper".locations."= /v1/chat/completions" = {
    proxyPass = "http://127.0.0.1:11435";
    extraConfig = ''
      limit_except POST { deny all; }
      # A long region at ~20 tok/s plus a cold model load can take minutes.
      proxy_read_timeout 900s;
      client_max_body_size 1m;
    '';
  };
}
