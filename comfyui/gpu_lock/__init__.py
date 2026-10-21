# Share the 11 GB card with whisper / summarize / llm-proxy (comfyui.nix).
#
# Not a node — it adds none. On import it wraps PromptExecutor.execute so every
# prompt runs under the box-wide exclusive flock on /run/whisper-gpu.lock
# (bind-mounted to $GPU_LOCK). A busy GPU makes the prompt WAIT, like a queued
# summary; nothing is refused. After a prompt the lock and the loaded models are
# kept for a warm window (COMFY_GPU_IDLE_SECS), so iterating on a workflow
# doesn't reload ~10 GB per run. When the window passes idle, all models are
# unloaded and the cache emptied BEFORE the lock is released — a resident model
# without the lock would let a WhisperX container start next to it and OOM.
import fcntl
import logging
import os
import threading
import time

import execution
import comfy.model_management as mm

LOCK_PATH = os.environ.get("GPU_LOCK", "/run/gpu.lock")
IDLE_SECS = float(os.environ.get("COMFY_GPU_IDLE_SECS", "300"))

log = logging.getLogger("gpu_lock")
_mutex = threading.Lock()
_fd = None      # held lock fd, or None
_busy = False   # a prompt is executing
_gen = 0        # bumps on every prompt; a stale idle timer sees a newer value


def _acquire():
    global _fd
    if _fd is not None:
        return
    fd = os.open(LOCK_PATH, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.warning("gpu_lock: GPU busy (transcription/summary/LLM), prompt waits")
        t0 = time.monotonic()
        fcntl.flock(fd, fcntl.LOCK_EX)
        log.warning("gpu_lock: acquired after %.0fs", time.monotonic() - t0)
    _fd = fd


def _release_if_idle(gen):
    global _fd
    with _mutex:
        if _busy or gen != _gen or _fd is None:
            return
        mm.unload_all_models()
        mm.soft_empty_cache(True)
        fcntl.flock(_fd, fcntl.LOCK_UN)
        os.close(_fd)
        _fd = None
        log.info("gpu_lock: idle %.0fs, models unloaded, lock released", IDLE_SECS)


_orig_execute = execution.PromptExecutor.execute


def _execute(self, *args, **kwargs):
    global _busy, _gen
    with _mutex:
        _busy = True
        _gen += 1
        try:
            _acquire()
        except BaseException:
            _busy = False
            raise
    try:
        return _orig_execute(self, *args, **kwargs)
    finally:
        with _mutex:
            _busy = False
            t = threading.Timer(IDLE_SECS, _release_if_idle, args=(_gen,))
            t.daemon = True
            t.start()


if os.path.exists(LOCK_PATH):
    execution.PromptExecutor.execute = _execute
    log.info("gpu_lock: prompts serialize on %s, warm window %.0fs", LOCK_PATH, IDLE_SECS)
else:
    log.warning("gpu_lock: %s missing, running WITHOUT the shared GPU lock", LOCK_PATH)

NODE_CLASS_MAPPINGS = {}
