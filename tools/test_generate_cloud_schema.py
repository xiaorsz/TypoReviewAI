#!/usr/bin/env python3
"""Offline deployment-file checks. Run: python3 tools/test_generate_cloud_schema.py"""
import copy
import json
from pathlib import Path
import re
import unittest

from generate_cloud_schema import EXPECTED_ENTITIES, generate

SCHEMA_DIRECTORY = Path(__file__).resolve().parent / "cloud-schema"


class CloudSchemaGenerationTests(unittest.TestCase):
    def setUp(self):
        self.model = json.loads((SCHEMA_DIRECTORY / "CoachLab.native-model.json").read_text())
        self.users = (SCHEMA_DIRECTORY / "Users.original.ckdb").read_text()

    def testAllNativeEntitiesAndNewAIFieldsArePresentWithoutInventedApplicationTypes(self):
        text, fields = generate(self.model, self.users)
        actual = set(re.findall(r"RECORD TYPE (CD_\w+) \(", text))
        self.assertEqual(actual, {f"CD_{name}" for name in EXPECTED_ENTITIES})
        self.assertEqual(len(fields), 17)
        self.assertEqual(fields["CD_ReviewDailyPlan"]["CD_coachSubjectRawValue"], "STRING")
        self.assertEqual(fields["CD_ReviewDailyPlan"]["CD_coachRationale_ckAsset"], "ASSET")
        self.assertEqual(fields["CD_ReviewDailyPlan"]["CD_startedAt"], "TIMESTAMP")
        self.assertNotIn("RECORD TYPE CDMR", text)
        self.assertNotIn('RECORD TYPE "cloudkit.share"', text)

    def testNativeScalarMappingPreservesUUIDAndVariableLengthSemantics(self):
        _, fields = generate(self.model, self.users)
        self.assertEqual(fields["CD_ReviewItem"]["CD_id"], "STRING")
        self.assertNotIn("CD_id_ckAsset", fields["CD_ReviewItem"])
        self.assertEqual(fields["CD_ReviewItem"]["CD_content"], "STRING")
        self.assertEqual(fields["CD_ReviewItem"]["CD_content_ckAsset"], "ASSET")
        self.assertEqual(fields["CD_ReviewItem"]["CD_nextReviewAt"], "TIMESTAMP")
        self.assertEqual(fields["CD_ReviewItem"]["CD_stage"], "INT64")
        self.assertEqual(fields["CD_AppSettings"]["CD_aiSummaryEnabled"], "INT64")
        for values in fields.values():
            self.assertEqual(values["CD_entityName"], "STRING")
            self.assertEqual(values["CD_moveReceipt"], "BYTES")

    def testOriginalUsersDefinitionAndOnlyItsPublicGrantsAreUnchanged(self):
        text, _ = generate(self.model, self.users)
        expected_users = re.search(r"RECORD TYPE Users\s*\(.*?\);", self.users, re.S).group(0)
        actual_users = re.search(r"RECORD TYPE Users\s*\(.*?\);", text, re.S).group(0)
        self.assertEqual(actual_users, expected_users)
        remainder = text.replace(actual_users, "")
        self.assertNotIn("GRANT", remainder)
        self.assertEqual(text.count('"___recordID" REFERENCE QUERYABLE'), 17)

    def testDifferentContainersMissingModelsAndUntrustedTemplatesFailClosed(self):
        for mutation in ["container", "entity", "template"]:
            with self.subTest(mutation=mutation):
                model = copy.deepcopy(self.model)
                template = self.users
                if mutation == "container": model["containerIdentifier"] = "iCloud.some.other.app"
                if mutation == "entity": model["entities"].pop()
                if mutation == "template": template += "\nRECORD TYPE Other (name STRING);"
                with self.assertRaises(ValueError): generate(model, template)

    def testEncryptionTransformersRelationshipsAndUnknownTypesRequireNativeReview(self):
        for mutation in ["encryption", "transformer", "relationship", "type"]:
            with self.subTest(mutation=mutation):
                model = copy.deepcopy(self.model)
                entity = model["entities"][0]
                attribute = entity["attributes"][0]
                if mutation == "encryption": attribute["allowsCloudEncryption"] = True
                if mutation == "transformer": attribute["valueTransformerName"] = "NeedsReview"
                if mutation == "relationship": entity["relationships"] = [{"name": "children"}]
                if mutation == "type": attribute["attributeTypeName"] = "UnknownType"
                with self.assertRaises(ValueError): generate(model, self.users)

    def testCheckedDeploymentArtifactMatchesExactInputs(self):
        text, fields = generate(self.model, self.users)
        self.assertEqual((SCHEMA_DIRECTORY / "CoachLab.ckdb").read_text(), text)
        manifest = json.loads((SCHEMA_DIRECTORY / "CoachLab.manifest.json").read_text())
        self.assertEqual(manifest["applicationRecordTypes"], len(fields))
        self.assertEqual(manifest["applicationFieldsIncludingOverflowAndMetadata"], 264)
        self.assertEqual(manifest["publicPermissionsForApplicationTypes"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
