"""Static checks for the watermark-test Synapse artifacts in synapse/.

Synapse only reports broken references when you open Studio or run a Debug, so catch
them here: valid JSON, every reference resolves, unique activity names, and the parent
pipeline still mirrors the client canvas it was rebuilt from.
"""
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1] / "synapse"
KINDS = ["pipeline", "dataset", "linkedService", "notebook", "trigger"]
PARENT = "pl_watermark_incremental_parent"


def load(kind):
    return {p.stem: json.loads(p.read_text()) for p in sorted((ROOT / kind).glob("*.json"))}


ART = {k: load(k) for k in KINDS}


def walk(activities):
    """Yield (activity, sibling names) for every activity, including nested ones."""
    names = {a["name"] for a in activities}
    for a in activities:
        yield a, names
        tp = a.get("typeProperties", {})
        for key in ("activities", "ifTrueActivities", "ifFalseActivities"):
            if key in tp:
                yield from walk(tp[key])


def by_name(pipeline):
    return {a["name"]: a for a, _ in walk(ART["pipeline"][pipeline]["properties"]["activities"])}


def test_every_file_name_matches_artifact_name():
    for kind, items in ART.items():
        for stem, doc in items.items():
            assert doc["name"] == stem, f"{kind}/{stem}.json has name {doc['name']!r}"


@pytest.mark.parametrize("pipeline", sorted(ART["pipeline"]))
def test_pipeline_references_resolve(pipeline):
    for a, siblings in walk(ART["pipeline"][pipeline]["properties"]["activities"]):
        for d in a.get("dependsOn", []):
            assert d["activity"] in siblings, f"{a['name']} depends on missing {d['activity']}"
        tp = a.get("typeProperties", {})
        if a["type"] == "ExecutePipeline":
            assert tp["pipeline"]["referenceName"] in ART["pipeline"]
        if a["type"] == "SynapseNotebook":
            assert tp["notebook"]["referenceName"] in ART["notebook"]
        refs = a.get("inputs", []) + a.get("outputs", []) + ([tp["dataset"]] if "dataset" in tp else [])
        for r in refs:
            assert r["referenceName"] in ART["dataset"], f"{a['name']}: missing dataset {r['referenceName']}"
        if "linkedServiceName" in a:
            assert a["linkedServiceName"]["referenceName"] in ART["linkedService"]


@pytest.mark.parametrize("pipeline", sorted(ART["pipeline"]))
def test_activity_names_unique_across_pipeline(pipeline):
    names = [a["name"] for a, _ in walk(ART["pipeline"][pipeline]["properties"]["activities"])]
    assert len(names) == len(set(names)), "Synapse requires unique names, nested activities included"


def test_datasets_use_known_linked_services():
    for name, d in ART["dataset"].items():
        assert d["properties"]["linkedServiceName"]["referenceName"] in ART["linkedService"], name


def test_parent_mirrors_client_canvas():
    acts = by_name(PARENT)
    assert len(acts) == 19

    def conds(name):
        return {d["activity"]: d["dependencyConditions"] for d in acts[name]["dependsOn"]}

    assert conds("Lookup_Large_Tables") == {"ForEach1": ["Completed"]}
    assert conds("Run Loop Static Load") == {"ForEach1_copy2": ["Succeeded"]}
    assert conds("Lookup1_copy1") == {"ForEach1_copy2": ["Completed"]}
    assert conds("Error Report Email copy1") == {"Run Loop Static Load": ["Failed"]}
    assert conds("Notebook1") == {"Run Loop Static Load": ["Succeeded"], "ForEach1_copy1": ["Succeeded"]}
    for name in ("Lookup1_copy1", "ForEach1_copy1"):
        assert acts[name].get("state") == "Inactive"
        assert acts[name].get("onInactiveMarkAs") == "Succeeded"
    assert acts["ForEach1_copy2"]["typeProperties"]["isSequential"] is True


def test_notebooks_have_parameters_cell():
    for name, nb in ART["notebook"].items():
        tagged = [c for c in nb["properties"]["cells"] if "parameters" in c["metadata"].get("tags", [])]
        assert len(tagged) == 1, name
