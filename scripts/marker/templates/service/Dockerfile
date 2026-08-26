# marker service image — one image, three roles (worker / api / batch) selected
# by the command in compose / k8s.
#
# Uses the default (CUDA-enabled) torch wheel: runs on CPU out of the box, and
# uses the GPU automatically when the container has the NVIDIA runtime (K8s GPU
# nodes). Models are NOT baked in — they download on first run into /models,
# which should be a mounted volume/PVC shared across replicas (HF_HOME=/models).
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTORCH_ENABLE_MPS_FALLBACK=1 \
    HF_HOME=/models \
    TORCH_HOME=/models \
    REDIS_URL=redis://redis:6379/0 \
    OUTPUT_DIR=/data/output

WORKDIR /app

# System libs marker's OpenCV/image stack needs at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY tasks.py worker.py api.py enqueue_batch.py ./

# Default role: worker. Override in compose/k8s for the API or batch enqueuer.
CMD ["python", "worker.py"]
