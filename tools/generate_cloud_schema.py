#!/usr/bin/env python3
"""Generate a reviewable schema from the exact, offline-exported native model.

No CloudKit credentials, network calls, record creation, or deployment are used.
Mapping reference:
https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data
DSL/system-field reference:
https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow
https://github.com/apple-aiml-research/ml-comlet/blob/main/ckschema.ckdb
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

CONTAINER = "iCloud.cc.xiaorsz.dictation-coach-lab"
EXPECTED_ENTITIES = {
    "ReviewItem", "ReviewRecord", "SyncDeletion", "ReviewDailyPlan", "TaskItem",
    "TaskCompletion", "TaskSubitem", "TaskExecutionRecord", "TaskSubitemExecutionRecord",
    "AppSettings", "DictationSession", "DictationEntry", "ScheduleItem", "MediaAsset",
    "PointLedgerEntry", "PointRewardState", "CalculationRound",
}
TYPES = {
    "Int16": "INT64", "Int32": "INT64", "Int64": "INT64", "Bool": "INT64",
    "Double": "DOUBLE", "Float": "DOUBLE", "Date": "TIMESTAMP", "UUID": "STRING",
    "URI": "STRING", "String": "STRING", "Data": "BYTES",
}
SYSTEM_FIELDS = [
    '"___createTime" TIMESTAMP', '"___createdBy" REFERENCE', '"___etag" STRING',
    '"___modTime" TIMESTAMP', '"___modifiedBy" REFERENCE', '"___recordID" REFERENCE QUERYABLE',
]


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", value):
        raise ValueError(f"Unsupported model/field identifier: {value!r}")
    return value


def generate(model, original_schema):
    if model.get("containerIdentifier") != CONTAINER:
        raise ValueError("Native model export belongs to a different container")
    if model.get("source") != "NSManagedObjectModel.makeManagedObjectModel(for:)":
        raise ValueError("Expected an exact native managed-object model export")
    entities = model.get("entities", [])
    if len(entities) != len(EXPECTED_ENTITIES) or {e["name"] for e in entities} != EXPECTED_ENTITIES:
        raise ValueError("Expected exactly the 17 models used by this experimental app")

    # Keep the existing system Users type and its permissions byte-for-byte.
    # Refuse a larger template to avoid importing unrelated types or permissions.
    matches = list(re.finditer(r"RECORD\s+TYPE\s+(?:\"Users\"|Users)\s*\(.*?\);", original_schema, re.S))
    type_count = len(re.findall(r"\bRECORD\s+TYPE\b", original_schema))
    if len(matches) != 1 or type_count != 1:
        raise ValueError("Template must be the current container export containing only Users")
    users = matches[0].group(0)
    output = ["DEFINE SCHEMA", "", users, ""]
    field_manifest = {}
    for entity in sorted(entities, key=lambda value: value["name"]):
        name = identifier(entity["name"])
        if entity.get("relationships"):
            raise ValueError(f"{name} has relationships; use Apple's native schema initializer")
        fields = {"CD_entityName": "STRING", "CD_moveReceipt": "BYTES"}
        for attr in entity["attributes"]:
            if attr.get("transient"):
                continue
            field = "CD_" + identifier(attr["name"])
            native_type = attr["attributeTypeName"]
            if native_type not in TYPES or attr.get("valueTransformerName"):
                raise ValueError(f"Unsupported {name}.{attr['name']} type/transformer: {native_type}")
            if attr.get("allowsCloudEncryption"):
                raise ValueError(f"{name}.{attr['name']} is encrypted; verify native generated schema first")
            fields[field] = TYPES[native_type]
            # Core Data's variable-length field pairs are documented by Apple;
            # allowsExternalBinaryDataStorage is a local storage preference,
            # and does not remove the CloudKit overflow field.
            if native_type in {"String", "Data"}:
                fields[field + "_ckAsset"] = "ASSET"
        body = [f"{key} {value}" for key, value in sorted(fields.items())] + SYSTEM_FIELDS
        # This app uses only a private database. No public access is granted for
        # newly introduced application types. The system Users grant is unchanged.
        output += [f"RECORD TYPE CD_{name} (", ",\n".join(f"    {line}" for line in body), ");", ""]
        field_manifest[f"CD_{name}"] = fields
    return "\n".join(output), field_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-json", required=True, type=Path)
    parser.add_argument("--users-schema", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    raw = args.model_json.read_bytes()
    template = args.users_schema.read_text()
    schema, fields = generate(json.loads(raw), template)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(schema)
    manifest = {
        "containerIdentifier": CONTAINER,
        "nativeModelSHA256": hashlib.sha256(raw).hexdigest(),
        "usersTemplateSHA256": hashlib.sha256(template.encode()).hexdigest(),
        "schemaSHA256": hashlib.sha256(schema.encode()).hexdigest(),
        "applicationRecordTypes": len(fields),
        "applicationFieldsIncludingOverflowAndMetadata": sum(map(len, fields.values())),
        "source": "Exact native model + Apple documented field mapping; not a CloudKit printSchema dump",
        "publicPermissionsForApplicationTypes": [],
        "fields": fields,
    }
    args.output.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(args.output), "recordTypes": len(fields),
                      "fields": manifest["applicationFieldsIncludingOverflowAndMetadata"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
