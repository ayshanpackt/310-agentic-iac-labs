#!/usr/bin/env python3
"""Negative and positive tests for the FinOps gate. Run from the lab directory:

    python3 finops/test_gate.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "gate.py")
sys.path.insert(0, HERE)
import gate  # noqa: E402

GOOD_TAGS = {"Environment": "lab", "Owner": "m12-lab", "ManagedBy": "loop-agent"}


def plan(resources=(), child_modules=()):
    return {
        "format_version": "1.2",
        "planned_values": {
            "root_module": {"resources": list(resources), "child_modules": list(child_modules)}
        },
    }


def instance(address, itype="t3.micro", tags=GOOD_TAGS, rtype="aws_instance", **extra):
    values = {"instance_type": itype}
    if tags is not None:
        values["tags"] = dict(tags)
    r = {"address": address, "mode": "managed", "type": rtype, "values": values}
    r.update(extra)
    return r


class GateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, content):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content if isinstance(content, str) else json.dumps(content))
        return path

    def run_gate(self, path):
        proc = subprocess.run([sys.executable, GATE, path], capture_output=True, text=True)
        return proc.returncode, proc.stdout

    # --- structurally invalid plans must be rejected, never passed -------------

    def test_empty_object_is_rejected(self):
        code, out = self.run_gate(os.path.join(HERE, "plan-empty.json"))
        self.assertEqual(code, 2, out)
        self.assertIn("FINOPS GATE ERROR", out)

    def test_invalid_json_is_rejected(self):
        code, out = self.run_gate(self.write("bad.json", "{not json"))
        self.assertEqual(code, 2, out)

    def test_missing_file_is_rejected(self):
        code, out = self.run_gate(os.path.join(self.tmp.name, "nope.json"))
        self.assertEqual(code, 2, out)

    def test_missing_root_module_is_rejected(self):
        code, out = self.run_gate(self.write("p.json", {"format_version": "1.2", "planned_values": {}}))
        self.assertEqual(code, 2, out)

    def test_missing_format_version_is_rejected(self):
        p = plan()
        del p["format_version"]
        code, out = self.run_gate(self.write("p.json", p))
        self.assertEqual(code, 2, out)

    def test_resources_not_a_list_is_rejected(self):
        p = plan()
        p["planned_values"]["root_module"]["resources"] = {"oops": 1}
        with self.assertRaises(gate.PlanError):
            gate.check(self.write("p.json", p))

    # --- child modules are walked recursively ---------------------------------

    def test_child_module_resources_are_counted(self):
        children = [
            {
                "address": "module.a",
                "resources": [instance(f"module.a.aws_instance.x[{i}]") for i in range(6)],
                "child_modules": [
                    {
                        "address": "module.a.module.b",
                        "resources": [instance(f"module.a.module.b.aws_instance.y[{i}]") for i in range(5)],
                    }
                ],
            }
        ]
        violations = gate.check(self.write("p.json", plan(child_modules=children)))
        self.assertEqual(violations, ["resource count 11 exceeds max 10"])

    def test_child_module_violations_are_reported_with_full_address(self):
        violations = gate.check(os.path.join(HERE, "plan-nested.json"))
        self.assertEqual(
            violations,
            [
                "module.workers.aws_instance.worker[0]: missing tags ['Environment', 'Owner', 'ManagedBy']",
                "module.workers.aws_instance.worker[0]: instance_type m5.24xlarge not in ['t3.medium', 't3.micro', 't3.small']",
            ],
        )

    # --- a missing tags field is missing tags ----------------------------------

    def test_absent_tags_field_on_aws_resource_is_a_violation(self):
        p = plan([instance("aws_instance.a", tags=None)])
        violations = gate.check(self.write("p.json", p))
        self.assertEqual(violations, ["aws_instance.a: missing tags ['Environment', 'Owner', 'ManagedBy']"])

    def test_null_tags_on_aws_resource_is_a_violation(self):
        r = instance("aws_s3_bucket.b", rtype="aws_s3_bucket")
        r["values"] = {"tags": None}
        violations = gate.check(self.write("p.json", plan([r])))
        self.assertEqual(violations, ["aws_s3_bucket.b: missing tags ['Environment', 'Owner', 'ManagedBy']"])

    def test_tags_all_from_default_tags_satisfies_the_rule(self):
        r = instance("aws_instance.a", tags=None)
        r["values"]["tags_all"] = dict(GOOD_TAGS)
        self.assertEqual(gate.check(self.write("p.json", plan([r]))), [])

    def test_local_file_without_tags_is_not_a_violation(self):
        r = {"address": "local_file.env", "mode": "managed", "type": "local_file", "values": {"filename": "x"}}
        self.assertEqual(gate.check(self.write("p.json", plan([r]))), [])

    def test_data_sources_do_not_count_as_resources(self):
        data = [instance(f"data.aws_ami.a[{i}]", rtype="aws_ami", mode="data") for i in range(20)]
        self.assertEqual(gate.check(self.write("p.json", plan(data))), [])

    # --- the committed fixtures behave as the lab says --------------------------

    def test_in_budget_fixture_passes(self):
        code, out = self.run_gate(os.path.join(HERE, "plan-in-budget.json"))
        self.assertEqual(code, 0, out)
        self.assertIn("within policy", out)

    def test_over_budget_fixture_fails_with_both_violations(self):
        code, out = self.run_gate(os.path.join(HERE, "plan-over-budget.json"))
        self.assertEqual(code, 1, out)
        self.assertIn("aws_instance.worker[0]: missing tags ['Owner', 'ManagedBy']", out)
        self.assertIn("instance_type m5.24xlarge not in", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
