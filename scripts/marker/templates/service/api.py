"""marker ingestion API — thin HTTP front door that enqueues conversion jobs.

The RAG ingestion pipeline POSTs a document reference (a path reachable by the
workers, i.e. on the shared input volume/PVC) and polls for status. Heavy work
happens on the workers, not here.

Env:
  REDIS_URL    default redis://localhost:6379/0
  MARKER_QUEUE default "marker"
  OUTPUT_DIR   default /data/output
  JOB_TIMEOUT  default 3600 (seconds)
"""
import os
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from redis import Redis
from rq import Queue
from rq.job import Job

import tasks

REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
QUEUE_NAME = os.environ.get("MARKER_QUEUE", "marker")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/data/output")
JOB_TIMEOUT = int(os.environ.get("JOB_TIMEOUT", "3600"))

app = FastAPI(title="marker ingestion API")
_conn = Redis.from_url(REDIS_URL)
_queue = Queue(QUEUE_NAME, connection=_conn, default_timeout=JOB_TIMEOUT)


class JobIn(BaseModel):
    path: str                                  # reachable by the workers (shared volume)
    output_format: str = "markdown"            # markdown | json | html | chunks
    output_dir: Optional[str] = None
    use_llm: bool = False
    force_ocr: bool = False
    page_range: Optional[str] = None


@app.get("/healthz")
def healthz():
    try:
        _conn.ping()
        return {"ok": True}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(503, f"redis unavailable: {exc}")


@app.post("/jobs")
def enqueue(body: JobIn):
    opts = {
        "output_format": body.output_format,
        "output_dir": body.output_dir or OUTPUT_DIR,
    }
    if body.use_llm:
        opts["use_llm"] = True
    if body.force_ocr:
        opts["force_ocr"] = True
    if body.page_range:
        opts["page_range"] = body.page_range

    job = _queue.enqueue(tasks.convert_document, body.path, opts)
    return {"job_id": job.id, "status": job.get_status()}


@app.get("/jobs/{job_id}")
def job_status(job_id: str):
    try:
        job = Job.fetch(job_id, connection=_conn)
    except Exception:  # noqa: BLE001
        raise HTTPException(404, "job not found")
    return {
        "job_id": job.id,
        "status": job.get_status(),
        "result": job.result,
        "error": job.exc_info if job.is_failed else None,
    }
