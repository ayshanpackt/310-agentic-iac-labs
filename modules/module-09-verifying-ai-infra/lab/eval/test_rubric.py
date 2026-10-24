#!/usr/bin/env python3
"""Tests for rubric.py. Run from the lab directory:

    python3 -m unittest discover -s eval -p 'test_*.py'

The negative cases are the point. A rubric that can be satisfied by the right words in a
comment is not a rubric, it is a keyword search."""
import os
import tempfile
import unittest

import rubric

HERE = os.path.dirname(os.path.abspath(__file__))


def check_text(text):
    with tempfile.NamedTemporaryFile("w", suffix=".tf", delete=False) as f:
        f.write(text)
        path = f.name
    try:
        return rubric.check(path)
    finally:
        os.unlink(path)


class FixtureFiles(unittest.TestCase):
    def test_good_fixture_passes(self):
        ok, violations = rubric.check(os.path.join(HERE, "fixture-good.tf"))
        self.assertTrue(ok, violations)

    def test_bad_fixture_fails_on_both_buckets(self):
        ok, violations = rubric.check(os.path.join(HERE, "fixture-bad.tf"))
        self.assertFalse(ok)
        self.assertEqual(
            violations,
            [
                "aws_s3_bucket.reports: missing tags ['Owner', 'ManagedBy']",
                "aws_s3_bucket.backups: missing tags ['Environment', 'Owner', 'ManagedBy']",
            ],
        )

    def test_tag_names_only_in_comments_fail(self):
        ok, violations = rubric.check(os.path.join(HERE, "fixture-comment-only.tf"))
        self.assertFalse(ok, "tag names in a comment must not satisfy the rubric")
        self.assertEqual(
            violations,
            ["aws_s3_bucket.reports: missing tags ['Environment', 'Owner', 'ManagedBy']"],
        )


class NegativeCases(unittest.TestCase):
    def test_commented_out_tags_block_fails(self):
        ok, _ = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "x"\n'
            "  # tags = {\n"
            '  #   Environment = "lab"\n'
            '  #   Owner       = "me"\n'
            '  #   ManagedBy   = "terraform"\n'
            "  # }\n"
            "}\n"
        )
        self.assertFalse(ok)

    def test_block_comment_fails(self):
        ok, _ = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "x"\n'
            '  /* tags = { Environment = "lab", Owner = "me", ManagedBy = "tf" } */\n'
            "}\n"
        )
        self.assertFalse(ok)

    def test_tag_names_inside_a_string_value_fail(self):
        ok, _ = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "Environment-Owner-ManagedBy"\n'
            "}\n"
        )
        self.assertFalse(ok)

    def test_tags_in_a_different_attribute_fail(self):
        ok, _ = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "x"\n'
            "  labels = {\n"
            '    Environment = "lab"\n'
            '    Owner       = "me"\n'
            '    ManagedBy   = "terraform"\n'
            "  }\n"
            "}\n"
        )
        self.assertFalse(ok)

    def test_tags_on_a_neighbouring_resource_do_not_count(self):
        ok, violations = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "x"\n'
            "}\n"
            'resource "aws_sqs_queue" "q" {\n'
            "  tags = {\n"
            '    Environment = "lab"\n'
            '    Owner       = "me"\n'
            '    ManagedBy   = "terraform"\n'
            "  }\n"
            "}\n"
        )
        self.assertFalse(ok)
        self.assertEqual(len(violations), 1)

    def test_non_literal_tags_fail_closed(self):
        ok, violations = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "x"\n'
            "  tags   = merge(local.common_tags, { Owner = \"me\" })\n"
            "}\n"
        )
        self.assertFalse(ok)
        self.assertIn("not a literal map", violations[0])

    def test_empty_or_null_tag_value_counts_as_missing(self):
        ok, violations = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            "  tags = {\n"
            '    Environment = "lab"\n'
            '    Owner       = ""\n'
            "    ManagedBy   = null\n"
            "  }\n"
            "}\n"
        )
        self.assertFalse(ok)
        self.assertEqual(violations, ["aws_s3_bucket.b: missing tags ['Owner', 'ManagedBy']"])

    def test_no_bucket_at_all_fails(self):
        ok, violations = check_text('resource "aws_sqs_queue" "q" {\n}\n')
        self.assertFalse(ok)
        self.assertEqual(violations, ["no aws_s3_bucket resource found"])

    def test_missing_file_fails(self):
        ok, violations = rubric.check(os.path.join(HERE, "does-not-exist.tf"))
        self.assertFalse(ok)
        self.assertTrue(violations[0].startswith("file not found"))


class PositiveCases(unittest.TestCase):
    def test_quoted_keys_pass(self):
        ok, violations = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            "  tags = {\n"
            '    "Environment" = "lab"\n'
            '    "Owner"       = "me"\n'
            '    "ManagedBy"   = "terraform"\n'
            "  }\n"
            "}\n"
        )
        self.assertTrue(ok, violations)

    def test_single_line_map_passes(self):
        ok, violations = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  tags = { Environment = "lab", Owner = "me", ManagedBy = "terraform" }\n'
            "}\n"
        )
        self.assertTrue(ok, violations)

    def test_comments_and_interpolation_inside_a_real_block_pass(self):
        ok, violations = check_text(
            'resource "aws_s3_bucket" "b" {\n'
            '  bucket = "x-${var.env}" # a } brace in a comment\n'
            "  tags = {\n"
            '    Environment = var.env        # trailing comment\n'
            '    Owner       = "team-${lookup(var.owners, "x", "}")}"\n'
            '    ManagedBy   = "terraform"\n'
            "    Extra       = \"fine\"\n"
            "  }\n"
            "}\n"
        )
        self.assertTrue(ok, violations)


if __name__ == "__main__":
    unittest.main()
