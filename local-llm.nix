{ config, pkgs, lib, ... }:

# GPU-lock-aware, OpenAI-compatible chat endpoint in front of Ollama, with two
# clients and two paths:
#
# 1. Text (default path) — interactive LAN clients, first user the Emacs
#    proofreader `tchecker` in ~/config. Backed by the summarizer's Qwen3:
#      POST http://192.168.85.30:8990/v1/chat/completions   (nginx, LAN)
#           body = {"messages": [...], "temperature": 0.0}   (OpenAI shape)
#      200  -> {"choices": [{"message": {"role": "assistant", "content": "..."}}]}
#    The request's "model" is ignored here: always LLM_PROXY_MODEL.
#
# 2. Vision passthrough — any request whose "model" is listed in
#    LLM_PROXY_VISION_MODELS (OpenBin, openbin.nix, on 127.0.0.1:11435 directly).
#    Full OpenAI chat-completions semantics incl. SSE streaming, translated to
#    Ollama's NATIVE /api/chat, because Ollama's own /v1 endpoint
#      - rejects WebP images ("Failed to load image or audio file", llama.cpp's
#        loader has no WebP) — and OpenBin re-encodes every photo > 1024 px to
#        WebP, server- and client-side. We transcode those to JPEG (Pillow).
#      - ignores "keep_alive", so with the box-wide OLLAMA_KEEP_ALIVE=0 every
#        photo analysis would reload the 6 GB model; native /api/chat honours it.
#      - can't set num_ctx (several 1024 px images need ~1k tokens each) or
#        think=false.
#    Verified on Ollama 0.30.6, 2026-11-18.
#
#   503 -> GPU busy (a transcription or summary holds the lock) — the client is
#          expected to fall back / retry later, NOT to wait.
#
# Ollama itself stays on 127.0.0.1: it has no auth (anyone reaching it could
# pull/delete models) and, more importantly, a direct call would bypass the GPU
# lock. Loading a model next to a running WhisperX container OOMs one of them.
#
# GPU LOCK + WARM WINDOW: the proxy takes /run/whisper-gpu.lock NON-blocking
# (busy -> 503 immediately) and then KEEPS it, with the model loaded, for an idle
# window after each request. Back-to-back calls (proofreading paragraph after
# paragraph, photo after photo) thus skip the multi-second reload. When the
# window passes without a request it unloads the model, waits until the VRAM is
# actually free, and only then releases the lock — so a whisper job queued
# meanwhile waits at most one window and never starts next to the resident LLM.
# Holding the lock is what makes the warm model safe; the two are inseparable.
# Switching between the text and the vision model within a window unloads the
# other one first (9.3 GB + 6 GB don't fit in 11 GB together).
let
  python = pkgs.python3.withPackages (ps: [ ps.pillow ]);
  proxyPy = pkgs.writeText "llm-proxy.py" ''
    import base64, fcntl, io, json, os, re, signal, sys, time, uuid
    import urllib.error, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from PIL import Image

    OLLAMA    = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    MODEL     = os.environ.get("LLM_PROXY_MODEL", "qwen3:14b")
    LOCK_PATH = os.environ.get("GPU_LOCK", "/run/whisper-gpu.lock")
    PORT      = int(os.environ.get("LLM_PROXY_PORT", "11435"))
    IDLE_SECS = int(os.environ.get("LLM_PROXY_IDLE_SECS", "180"))
    NUM_CTX   = int(os.environ.get("LLM_PROXY_NUM_CTX", "8192"))
    VISION_MODELS  = set(os.environ.get("LLM_PROXY_VISION_MODELS", "").split())
    VISION_NUM_CTX = int(os.environ.get("LLM_PROXY_VISION_NUM_CTX", "16384"))
    # OpenBin's prompts are hard-coded English and its per-user custom prompt
    # only covers the first analysis (not reanalysis/correction/commands), so
    # the German rule is appended here to the system prompt of every request
    # for a vision model (= every OpenBin request).
    VISION_GERMAN = os.environ.get("LLM_PROXY_VISION_GERMAN", "") == "1"
    GERMAN_RULE = (
        "LANGUAGE RULE (overrides any English examples above): write every "
        "human-readable value in German - bin names, item names, tags, notes, "
        "interpretations and answers. Use the everyday German term a German "
        "hardware store would use: \"Lack\" not \"Lacquer\", \"Wandfarbe\" not "
        "\"Wall Paint\", \"Holzlasur\", \"Spachtelmasse\", \"Schrauben\", "
        "\"Akkuschrauber\". Follow German capitalization instead of English "
        "Title Case, but always start a name with a capital letter (\"Weißer "
        "Seidenmattlack\"). Keep brand and product names exactly as printed on the "
        "label. JSON keys, action types and other field names stay exactly as "
        "specified (English)."
    )
    # Ollama's own keep_alive outlives our window, so normally WE unload; it is
    # only the safety net if this process dies without running its cleanup.
    KEEP_ALIVE = str(IDLE_SECS + 120) + "s"
    THINK_RE  = re.compile(r"<think>.*?</think>\s*", re.DOTALL)
    DATA_URL_RE = re.compile(r"^data:([^;,]*)((?:;[^;,]*)*),(.*)$", re.DOTALL)

    lock_fd = None      # held GPU lock (fd), or None
    loaded = None       # model we loaded while holding the lock, or None
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

    def wait_unloaded(model, timeout=30.0):
        # Same as summarize.nix: the VRAM free can lag the unload response.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(OLLAMA + "/api/ps", timeout=5) as r:
                    running = json.load(r).get("models", [])
            except Exception:
                return
            if not any(model in (m.get("name"), m.get("model")) for m in running):
                return
            time.sleep(0.5)

    def unload(model):
        try:
            ollama_post("/api/generate", {"model": model, "keep_alive": 0}, 30)
        except Exception as e:
            log("unload failed:", e)
        wait_unloaded(model)

    def use_model(model):
        # Called with the lock held, before each Ollama call.
        global loaded
        if loaded is not None and loaded != model:
            unload(loaded)
            log("switched model:", loaded, "->", model)
        loaded = model

    def release():
        global lock_fd, loaded
        if lock_fd is None:
            return
        if loaded is not None:
            unload(loaded)
            loaded = None
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)
            lock_fd = None
        log("model unloaded, gpu lock released")

    # ---- path 1: text (Emacs proofreader) --------------------------------

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
        use_model(MODEL)
        out = ollama_post("/api/chat", payload, 900)
        if out.get("error"):
            raise RuntimeError("ollama: " + str(out["error"]))
        return THINK_RE.sub("", (out.get("message") or {}).get("content", "")).strip()

    # ---- path 2: vision passthrough (OpenBin) ----------------------------

    class Stats:
        def __init__(self):
            self.images = 0
            self.transcoded = 0
            self.bytes = 0

    def to_ollama_image(url, st):
        # OpenAI image_url (data: URL) -> bare base64 JPEG/PNG for Ollama.
        m = DATA_URL_RE.match(url or "")
        if not m or ";base64" not in m.group(2):
            raise ValueError("only base64 data: URLs are supported as images")
        raw = base64.b64decode(m.group(3))
        st.images += 1
        st.bytes += len(raw)
        if raw[:3] == b"\xff\xd8\xff" or raw[:8] == b"\x89PNG\r\n\x1a\n":
            return m.group(3)
        img = Image.open(io.BytesIO(raw))
        img.load()
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=92)
        st.transcoded += 1
        return base64.b64encode(buf.getvalue()).decode("ascii")

    def to_ollama_messages(messages, st):
        if not isinstance(messages, list) or not messages:
            raise ValueError("messages must be a non-empty list")
        out = []
        for m in messages:
            role = m.get("role")
            if role not in ("system", "user", "assistant"):
                raise ValueError("unsupported role: %r" % role)
            content = m.get("content")
            texts, images = [], []
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                for part in content:
                    kind = part.get("type")
                    if kind == "text":
                        texts.append(part.get("text") or "")
                    elif kind == "image_url":
                        images.append(to_ollama_image((part.get("image_url") or {}).get("url"), st))
                    else:
                        raise ValueError("unsupported content part: %r" % kind)
            elif content is not None:
                raise ValueError("unsupported content type")
            msg = {"role": role, "content": "\n\n".join(texts)}
            if images:
                msg["images"] = images
            out.append(msg)
        return out

    def vision_payload(req, st):
        options = {"num_ctx": VISION_NUM_CTX}
        if req.get("temperature") is not None:
            options["temperature"] = float(req["temperature"])
        if req.get("top_p") is not None:
            options["top_p"] = float(req["top_p"])
        max_tokens = req.get("max_completion_tokens") or req.get("max_tokens")
        if max_tokens:
            options["num_predict"] = int(max_tokens)
        if req.get("seed") is not None:
            options["seed"] = int(req["seed"])
        if req.get("stop"):
            options["stop"] = req["stop"] if isinstance(req["stop"], list) else [req["stop"]]
        messages = to_ollama_messages(req.get("messages"), st)
        if VISION_GERMAN:
            sys_msg = next((m for m in messages if m["role"] == "system"), None)
            if sys_msg is None:
                messages.insert(0, {"role": "system", "content": GERMAN_RULE})
            else:
                sys_msg["content"] = (sys_msg["content"] + "\n\n" + GERMAN_RULE).strip()
            # Repeated at the very end: the 8B model follows recent text best.
            last_user = next((m for m in reversed(messages) if m["role"] == "user"), None)
            if last_user is not None:
                last_user["content"] = (last_user["content"] + "\n\n" + GERMAN_RULE).strip()
        payload = {
            "model": req["model"],
            "messages": messages,
            "stream": bool(req.get("stream")),
            "think": False,
            "keep_alive": KEEP_ALIVE,
            "options": options,
        }
        rf = req.get("response_format") or {}
        if rf.get("type") == "json_schema":
            payload["format"] = (rf.get("json_schema") or {}).get("schema") or "json"
        elif rf.get("type") == "json_object":
            payload["format"] = "json"
        return payload

    def finish_reason(obj):
        return "length" if obj.get("done_reason") == "length" else "stop"

    def usage_of(obj):
        p, c = obj.get("prompt_eval_count", 0), obj.get("eval_count", 0)
        return {"prompt_tokens": p, "completion_tokens": c, "total_tokens": p + c}

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
                if req.get("model") in VISION_MODELS:
                    return self.vision(req)
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

        def vision(self, req):
            t0 = time.monotonic()
            st = Stats()
            try:
                payload = vision_payload(req, st)
            except Exception as e:  # bad shape or undecodable image
                return self.error(400, "bad_request", str(e))
            use_model(payload["model"])
            r = urllib.request.Request(OLLAMA + "/api/chat",
                                       data=json.dumps(payload).encode("utf-8"),
                                       headers={"Content-Type": "application/json"})
            try:
                resp = urllib.request.urlopen(r, timeout=900)
            except urllib.error.HTTPError as e:
                detail = e.read().decode("utf-8", "replace")
                log("vision: ollama HTTP %d: %s" % (e.code, detail))
                return self.error(400 if e.code == 400 else 502, "upstream_error", detail)
            except Exception as e:
                log("vision: ollama failed:", e)
                return self.error(502, "upstream_error", str(e))
            cid = "chatcmpl-" + uuid.uuid4().hex
            created = int(time.time())
            base = {"id": cid, "created": created, "model": payload["model"]}
            last = {}
            n_out = 0
            with resp:
                if not payload["stream"]:
                    last = json.load(resp)
                    if last.get("error"):
                        return self.error(502, "upstream_error", str(last["error"]))
                    text = (last.get("message") or {}).get("content", "")
                    n_out = len(text)
                    self.send_json(200, dict(base, object="chat.completion", choices=[{
                        "index": 0, "finish_reason": finish_reason(last),
                        "message": {"role": "assistant", "content": text}}],
                        usage=usage_of(last)))
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()  # HTTP/1.0: the body ends when we close

                    def sse(obj):
                        self.wfile.write(b"data: " + json.dumps(obj).encode("utf-8") + b"\n\n")
                        self.wfile.flush()

                    def chunk(delta, fr=None, **extra):
                        return dict(base, object="chat.completion.chunk", choices=[{
                            "index": 0, "delta": delta, "finish_reason": fr}], **extra)

                    try:
                        sse(chunk({"role": "assistant", "content": ""}))
                        for line in resp:
                            if not line.strip():
                                continue
                            obj = json.loads(line)
                            if obj.get("error"):
                                log("vision: ollama stream error:", obj["error"])
                                sse({"error": {"message": str(obj["error"]), "type": "upstream_error"}})
                                break
                            piece = (obj.get("message") or {}).get("content", "")
                            if piece:
                                n_out += len(piece)
                                sse(chunk({"content": piece}))
                            if obj.get("done"):
                                last = obj
                                sse(chunk({}, finish_reason(obj), usage=usage_of(obj)))
                                break
                        self.wfile.write(b"data: [DONE]\n\n")
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        # Client aborted; leaving `with resp` closes the upstream
                        # connection, which makes Ollama stop generating.
                        log("vision: client disconnected, generation aborted")
            u = usage_of(last) if last else {}
            log("vision ok: %s, %d image(s) %d KB (%d transcoded to JPEG), "
                "%s prompt tok, %s out tok / %d chars, %.1fs" % (
                    payload["model"], st.images, st.bytes // 1024, st.transcoded,
                    u.get("prompt_tokens", "?"), u.get("completion_tokens", "?"),
                    n_out, time.monotonic() - t0))

        def log_message(self, fmt, *args):
            pass  # access log is nginx's job

    def on_term(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, on_term)
    # Single-threaded on purpose: requests serialize, and the idle check below
    # runs between them — no threads touching the lock.
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    server.timeout = 5
    log("listening on 127.0.0.1:%d, text model %s, vision models %s, idle window %ds" % (
        PORT, MODEL, " ".join(sorted(VISION_MODELS)) or "-", IDLE_SECS))
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
      # Passed through with images (OpenBin). Must be pulled: summarize.nix
      # loadModels. The -instruct tag has no thinking mode at all.
      LLM_PROXY_VISION_MODELS = "qwen3-vl:8b-instruct";
      # OpenBin sends up to AI_MAX_PHOTOS_PER_REQUEST (20, openbin.nix) photos
      # at 1024 px, ~0.5-0.85k tokens each, plus a ~1.3k+ prompt. 32k on the
      # 11 GB 1080 Ti: ~10.3 GB (7.9 GB measured at 16k + ~2.4 GB KV cache).
      LLM_PROXY_VISION_NUM_CTX = "32768";
      # Item/bin names in German ("Lack", not "Lacquer"); see GERMAN_RULE.
      LLM_PROXY_VISION_GERMAN = "1";
      GPU_LOCK = "/run/whisper-gpu.lock";
    };
    serviceConfig = {
      ExecStart = "${python}/bin/python3 ${proxyPy}";
      Restart = "on-failure";
      # Unload + VRAM wait on stop can take a few seconds.
      TimeoutStopSec = "60s";
      DynamicUser = true;
      # The lock file is 0660 root:whisper (summarize.nix tmpfiles).
      SupplementaryGroups = [ "whisper" ];
    };
  };

  # Exact-match, so it never shadows the PUT-only audio inbox at "/" (whisper.nix).
  # LAN clients get the text path only in practice: the 1 MB body cap keeps
  # photo payloads out (OpenBin talks to 127.0.0.1:11435 directly).
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
