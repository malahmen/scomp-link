"""marker RQ worker launcher.

Uses RQ's SimpleWorker (no per-job fork) so marker's models load once and are
reused across jobs — and so a GPU/CUDA context isn't corrupted by forking.
Pre-warms the models at startup so the first job isn't slow.

Env:
  REDIS_URL   default redis://localhost:6379/0
  MARKER_QUEUE default "marker"
"""
import os

from redis import Redis
from rq import Queue, SimpleWorker

import tasks


def main():
    redis_url = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
    queue_name = os.environ.get("MARKER_QUEUE", "marker")

    # Warm the models before taking jobs (SimpleWorker runs jobs in-process).
    print(f"[worker] loading marker models …", flush=True)
    tasks.get_models()
    print(f"[worker] ready — consuming '{queue_name}' from {redis_url}", flush=True)

    conn = Redis.from_url(redis_url)
    queue = Queue(queue_name, connection=conn)
    SimpleWorker([queue], connection=conn).work()


if __name__ == "__main__":
    main()
