#!/usr/bin/env python3
"""Guard the GGUF model-fit estimator and its documented safety boundary."""
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
estimator = (ROOT / "lib/src/features/models/model_fit_estimator.dart").read_text(encoding="utf-8")
record = (ROOT / "lib/src/features/models/model_record.dart").read_text(encoding="utf-8")
inspector = (ROOT / "lib/src/features/models/rust_gguf_inspector.dart").read_text(encoding="utf-8")
parser = (ROOT / "core/runtime/src/gguf.rs").read_text(encoding="utf-8")
bridge = (ROOT / "core/bridge/src/api/simple.rs").read_text(encoding="utf-8")
page = (ROOT / "lib/src/features/models/models_page.dart").read_text(encoding="utf-8")
test = (ROOT / "test/model_fit_estimator_test.dart").read_text(encoding="utf-8")
workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"))
workflow_text = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

checks = {
    "GGUF parser reads per-architecture KV head and dimension metadata": all(
        field in parser for field in (
            "attention.head_count", "attention.head_count_kv",
            "attention.key_length", "attention.value_length",
        )
    ),
    "Rust bridge exposes all four optional GGUF attention dimensions": all(
        f"pub {field}: Option<u64>" in bridge for field in (
            "attention_head_count", "attention_head_count_kv",
            "attention_key_length", "attention_value_length",
        )
    ),
    "Dart model record persists four attention dimensions": all(
        f"'{field}':" in record for field in (
            "attention_head_count", "attention_head_count_kv",
            "attention_key_length", "attention_value_length",
        )
    ),
    "Dart inspector maps generated attention metadata": all(
        f"result.{field}" in inspector for field in (
            "attentionHeadCount", "attentionHeadCountKv",
            "attentionKeyLength", "attentionValueLength",
        )
    ),
    "KV estimator uses actual block/context/head/K/V dimensions and F16 bytes": (
        "BigInt.from(context)" in estimator and "BigInt.from(blocks)" in estimator
        and "aggregateKvWidth" in estimator and "BigInt.from(2)" in estimator
    ),
    "KV estimator uses conservative full-embedding fallback": "fullEmbeddingUpperBound" in estimator and "full-width multi-head attention fallback" in estimator,
    "Fallback KV test uses the correct 1 GiB arithmetic for its fixture": "expect(result.kvCacheBytes, 1073741824)" in test,
    "Estimator reports an uncertainty envelope, not one false-precision result": all(
        field in estimator for field in (
            "minimumRequiredBytes", "recommendedRequiredBytes", "upperRequiredBytes",
        )
    ),
    "Estimator mirrors the current native runtime base/context reserve": "384 * mib" in estimator and "128 * mib" in estimator,
    "Unsupported architectures remain unknown instead of claiming fit": "_attentionArchitectures.contains(architecture)" in estimator and "ModelFitStatus.unknown" in estimator,
    "Model-fit UI requires a verified local GGUF file before estimating": "_fileVerifier.verify(model)" in page and "ModelFitEstimator.estimate(" in page,
    "User can compare supported context sizes and apply them only after explicit confirmation": (
        "ChoiceChip" in page
        and "لا يبدل جلسة نشطة تلقائياً" in page
        and "اعتماد الإعداد وفحص الجاهزية" in page
        and "Insufficient" not in page
    ),
    "Estimator is explicitly advisory and does not bypass native preflight": "never bypasses it" in estimator and "فحص الذاكرة داخل محرك llama.cpp يظل إلزامياً" in estimator,
    "Fresh GGUF inspection overrides stale cached metadata and context options": (
        "freshInspection: verification.inspection" in page
        and "final trainingContext = freshInspection == null" in (ROOT / "lib/src/features/resources/adaptive_inference_policy.dart").read_text(encoding="utf-8")
        and "_hasCompleteAttentionDimensions(model, freshInspection)" in estimator
    ),
    "Dart tests cover GQA, fallback, insufficient RAM, unknown architectures and bad metadata": all(
        case in test for case in (
            "GGUF GQA dimensions", "full embedding width", "insufficient and tight",
            "unavailable memory", "state-space architectures", "inconsistent GGUF KV head dimensions",
            "fresh GGUF inspection overrides stale cached model metadata",
        )
    ),
    "CI executes model-fit estimator and migration contracts": (
        "scripts/test_model_fit_contract.py" in workflow_text
        and "scripts/test_model_fit_migration.py" in workflow_text
    ),
}

failed = [name for name, passed in checks.items() if not passed]
for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {name}")
if failed:
    raise SystemExit("Model-fit contract failures: " + ", ".join(failed))
print(f"Model-fit estimator contract PASS: {len(checks)} checks")
