"""Static checks on the Synapse artifacts in synapse/: valid JSON, names match file names,
and every reference points at an artifact that exists. Catches broken JSON before Publish."""
import json
from pathlib import Path

import pytest

SYNAPSE = Path(__file__).resolve().parents[1] / "synapse"
KINDS = {
    "LinkedServiceReference": "linkedService",
    "DatasetReference": "dataset",
    "PipelineReference": "pipeline",
}
ARTIFACTS = sorted(SYNAPSE.glob("*/*.json"))


def _refs(node):
    if isinstance(node, dict):
        if node.get("type") in KINDS and "referenceName" in node:
            yield KINDS[node["type"]], node["referenceName"]
        for v in node.values():
            yield from _refs(v)
    elif isinstance(node, list):
        for v in node:
            yield from _refs(v)


def test_artifacts_exist():
    assert ARTIFACTS, "no Synapse artifacts found"


@pytest.mark.parametrize("path", ARTIFACTS, ids=lambda p: f"{p.parent.name}/{p.name}")
def test_artifact_is_valid_and_named_after_file(path):
    doc = json.loads(path.read_text())
    assert doc["name"] == path.stem


@pytest.mark.parametrize("path", ARTIFACTS, ids=lambda p: f"{p.parent.name}/{p.name}")
def test_references_resolve(path):
    for kind, name in _refs(json.loads(path.read_text())):
        assert (SYNAPSE / kind / f"{name}.json").exists(), f"{path.name} references missing {kind}/{name}"


def test_curate_has_failure_path():
    pipeline = json.loads((SYNAPSE / "pipeline" / "pl_curate.json").read_text())
    fail = [a for a in pipeline["properties"]["activities"] if a["type"] == "Fail"]
    assert fail and fail[0]["typeProperties"]["errorCode"] == "CURATE_FAILED"
    assert fail[0]["dependsOn"][0]["dependencyConditions"] == ["Failed"]
