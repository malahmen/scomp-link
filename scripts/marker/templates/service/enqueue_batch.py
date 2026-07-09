"""Bulk-enqueue every supported document in a folder — the "convert a whole
folder in one shot" path. It's a *producer*: it pushes one job per file onto the
same queue the workers consume, so throughput scales with worker replicas.

Usage:
  python enqueue_batch.py <input_dir> [--output_dir DIR] [--output_format FMT]
                          [--use_llm] [--force_ocr]

Env mirrors the workers: REDIS_URL, MARKER_QUEUE, OUTPUT_DIR, OUTPUT_FORMAT,
JOB_TIMEOUT.
"""
import argparse
import os

from redis import Redis
from rq import Queue

import tasks

SUPPORTED = {
    ".pdf", ".docx", ".pptx", ".xlsx", ".html", ".epub",
    ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".webp", ".gif", ".bmp",
}


def main():
    ap = argparse.ArgumentParser(description="Enqueue a folder of documents for marker conversion.")
    ap.add_argument("input_dir")
    ap.add_argument("--output_dir", default=os.environ.get("OUTPUT_DIR", "/data/output"))
    ap.add_argument("--output_format", default=os.environ.get("OUTPUT_FORMAT", "markdown"))
    ap.add_argument("--use_llm", action="store_true")
    ap.add_argument("--force_ocr", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.input_dir):
        raise SystemExit(f"not a directory: {args.input_dir}")

    conn = Redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"))
    queue = Queue(
        os.environ.get("MARKER_QUEUE", "marker"),
        connection=conn,
        default_timeout=int(os.environ.get("JOB_TIMEOUT", "3600")),
    )

    count = 0
    for root, _dirs, files in os.walk(args.input_dir):
        for name in sorted(files):
            if os.path.splitext(name)[1].lower() not in SUPPORTED:
                continue
            path = os.path.join(root, name)
            opts = {"output_format": args.output_format, "output_dir": args.output_dir}
            if args.use_llm:
                opts["use_llm"] = True
            if args.force_ocr:
                opts["force_ocr"] = True
            queue.enqueue(tasks.convert_document, path, opts)
            count += 1

    print(f"enqueued {count} document(s) onto the '{queue.name}' queue")


if __name__ == "__main__":
    main()
