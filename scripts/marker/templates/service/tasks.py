"""marker conversion task (RQ job function).

Grounded on marker's own `convert_single_cli`: load the model dict ONCE per
worker process and reuse it across every job (the CLI reloads it per file — the
whole point of a long-lived worker is to avoid that). Run with an RQ
*SimpleWorker* (no fork) so the loaded models — and any GPU/CUDA context — are
reused safely across jobs.
"""
import os

# Match marker's CLI environment (quiet gRPC/glog, MPS fallback for Macs).
os.environ.setdefault("GRPC_VERBOSITY", "ERROR")
os.environ.setdefault("GLOG_minloglevel", "2")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

_models = None


def get_models():
    """Load and cache marker's model dict once per process."""
    global _models
    if _models is None:
        from marker.models import create_model_dict
        _models = create_model_dict()
    return _models


def convert_document(fpath: str, options: dict | None = None) -> str:
    """Convert one document with marker; returns the output folder.

    `options` mirrors marker_single's flags, e.g.:
      {"output_format": "markdown", "output_dir": "/data/output",
       "use_llm": True, "force_ocr": True, "page_range": "0,5-10"}
    """
    from marker.config.parser import ConfigParser
    from marker.output import save_output

    if not os.path.exists(fpath):
        raise FileNotFoundError(fpath)

    models = get_models()
    config_parser = ConfigParser(options or {})

    converter_cls = config_parser.get_converter_cls()
    converter = converter_cls(
        config=config_parser.generate_config_dict(),
        artifact_dict=models,
        processor_list=config_parser.get_processors(),
        renderer=config_parser.get_renderer(),
        llm_service=config_parser.get_llm_service(),
    )
    rendered = converter(fpath)
    out_folder = config_parser.get_output_folder(fpath)
    save_output(rendered, out_folder, config_parser.get_base_filename(fpath))
    return out_folder
