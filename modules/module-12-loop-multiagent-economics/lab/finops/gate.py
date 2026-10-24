#!/usr/bin/env python3
"""FinOps gate: fails on resource-count, tag, or instance-type violations, read
straight from `terraform show -json`. No Infracost API key required, this checks
policy, not live pricing.

Exit codes: 0 within policy, 1 policy violations, 2 the file is not a plan the
gate can evaluate (missing, unreadable, or not `terraform show -json` output).
A plan the gate cannot read is never a pass."""
import json
import sys

MAX_RESOURCES = 10
REQUIRED_TAGS = ["Environment", "Owner", "ManagedBy"]
ALLOWED_INSTANCE_TYPES = {"t3.micro", "t3.small", "t3.medium"}
# Resource types from these providers must carry the required tags. A local_file
# or null_resource has no tags field by design and is not a FinOps violation.
TAGGED_TYPE_PREFIXES = ("aws_",)


class PlanError(Exception):
    """The file is not a `terraform show -json` plan the gate can evaluate."""


def load_plan(plan_path):
    try:
        with open(plan_path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except FileNotFoundError:
        raise PlanError(f"file not found: {plan_path}")
    except (OSError, ValueError) as exc:
        raise PlanError(f"not valid JSON: {plan_path}: {exc}")
    if not isinstance(plan, dict):
        raise PlanError("top level is not an object")
    if not isinstance(plan.get("format_version"), str):
        raise PlanError("missing format_version, not terraform show -json output")
    planned = plan.get("planned_values")
    if not isinstance(planned, dict):
        raise PlanError("missing planned_values")
    root = planned.get("root_module")
    if not isinstance(root, dict):
        raise PlanError("missing planned_values.root_module")
    return root


def walk_resources(module):
    """Yield every managed resource in this module and, recursively, its child modules."""
    resources = module.get("resources") or []
    if not isinstance(resources, list):
        raise PlanError("resources is not a list")
    for r in resources:
        if not isinstance(r, dict) or "address" not in r or "type" not in r:
            raise PlanError("resource entry missing address or type")
        if r.get("mode", "managed") == "managed":
            yield r
    children = module.get("child_modules") or []
    if not isinstance(children, list):
        raise PlanError("child_modules is not a list")
    for child in children:
        if not isinstance(child, dict):
            raise PlanError("child module entry is not an object")
        yield from walk_resources(child)


def check(plan_path):
    root = load_plan(plan_path)
    resources = list(walk_resources(root))
    violations = []
    if len(resources) > MAX_RESOURCES:
        violations.append(f"resource count {len(resources)} exceeds max {MAX_RESOURCES}")
    for r in resources:
        values = r.get("values") or {}
        if not isinstance(values, dict):
            raise PlanError(f"{r['address']}: values is not an object")
        if r["type"].startswith(TAGGED_TYPE_PREFIXES):
            # tags_all carries provider default_tags merged in; fall back to tags.
            # A missing field means no tags at all, which fails every required tag.
            tags = values.get("tags_all") or values.get("tags") or {}
            missing = [t for t in REQUIRED_TAGS if t not in tags]
            if missing:
                violations.append(f"{r['address']}: missing tags {missing}")
        instance_type = values.get("instance_type")
        if instance_type and instance_type not in ALLOWED_INSTANCE_TYPES:
            violations.append(
                f"{r['address']}: instance_type {instance_type} not in {sorted(ALLOWED_INSTANCE_TYPES)}"
            )
    return violations


def main():
    if len(sys.argv) != 2:
        print("usage: gate.py <path-to-terraform-plan-json>", file=sys.stderr)
        return 2

    try:
        violations = check(sys.argv[1])
    except PlanError as exc:
        print(f"FINOPS GATE ERROR: cannot evaluate {sys.argv[1]}: {exc}")
        return 2
    if violations:
        print("FINOPS GATE FAILED:")
        for v in violations:
            print(" -", v)
        return 1
    print(f"FinOps gate passed: {sys.argv[1]} within policy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
