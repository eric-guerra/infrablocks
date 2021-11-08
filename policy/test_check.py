from pathlib import Path

import pytest

import check

ROOT = Path(__file__).resolve().parent.parent


def write(tmp_path: Path, rel: str, body: str) -> Path:
    p = tmp_path / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body, encoding="utf-8")
    return p


def rules_hit(paths):
    return sorted({v.rule for v in check.check(paths)})


def test_repo_is_clean():
    files = [p for p in ROOT.rglob("*.tf") if ".terraform" not in p.parts]
    assert len(files) >= 14
    assert check.check(files) == []


def test_bare_bucket_violates_access_block_and_encryption(tmp_path):
    p = write(tmp_path, "mod/main.tf", 'resource "aws_s3_bucket" "raw" {\n  bucket = "x"\n}\n')
    assert rules_hit([p]) == ["s3-encryption", "s3-public-access"]


def test_access_block_must_reference_the_bucket(tmp_path):
    p = write(tmp_path, "mod/main.tf", '''
resource "aws_s3_bucket" "a" {
  bucket = "a"
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    }
  }
}
resource "aws_s3_bucket" "b" {
  bucket = "b"
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    }
  }
}
resource "aws_s3_bucket_public_access_block" "a" {
  bucket = aws_s3_bucket.a.id
}
''')
    vs = check.check([p])
    assert [v.address for v in vs] == ["aws_s3_bucket.b"]


def test_rds_rules(tmp_path):
    p = write(tmp_path, "mod/main.tf", '''
resource "aws_db_instance" "db" {
  engine              = "postgres"
  password            = var.db_password
  publicly_accessible = true
}
''')
    assert rules_hit([p]) == ["rds-encryption", "rds-password", "rds-private"]


@pytest.mark.parametrize("port,protocol,bad", [(443, "tcp", False), (80, "tcp", False), (22, "tcp", True), (0, "-1", True)])
def test_open_ingress(tmp_path, port, protocol, bad):
    p = write(tmp_path, "mod/main.tf", f'''
resource "aws_security_group" "sg" {{
  ingress {{
    from_port   = {port}
    to_port     = {port}
    protocol    = "{protocol}"
    cidr_blocks = ["0.0.0.0/0"]
  }}
}}
''')
    assert ("open-ingress" in rules_hit([p])) is bad


def test_private_cidr_ingress_is_fine(tmp_path):
    p = write(tmp_path, "mod/main.tf", '''
resource "aws_security_group" "sg" {
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
}
''')
    assert rules_hit([p]) == []


def test_unpinned_provider(tmp_path):
    p = write(tmp_path, "mod/main.tf", '''
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 3.0" }
    random = { source = "hashicorp/random" }
  }
}
''')
    vs = check.check([p])
    assert {v.address for v in vs} == {"provider.aws", "provider.random"}


def test_env_requires_locked_backend_and_tags(tmp_path):
    p = write(tmp_path, "envs/dev/main.tf", '''
terraform {
  backend "s3" {
    bucket = "state"
    key    = "dev.tfstate"
  }
}
locals {
  tags = { Environment = "dev" }
}
''')
    vs = check.check([p])
    assert {v.rule for v in vs} == {"remote-state", "required-tags"}
    assert "CostCenter" in next(v.message for v in vs if v.rule == "required-tags")


def test_env_without_backend(tmp_path):
    p = write(tmp_path, "envs/dev/main.tf", 'locals {\n  tags = { Environment = "d", Owner = "o", CostCenter = "c" }\n}\n')
    assert rules_hit([p]) == ["remote-state"]


@pytest.mark.parametrize("image,bad", [
    ("repo/app:latest", True),
    ("repo/app", True),
    ("123.dkr.ecr.us-east-1.amazonaws.com/app:1.4.2", False),
])
def test_image_pinning(tmp_path, image, bad):
    p = write(tmp_path, "mod/main.tf", f'module "svc" {{\n  source = "../x"\n  image  = "{image}"\n}}\n')
    assert ("pinned-image" in rules_hit([p])) is bad


def test_cli_exit_codes(tmp_path, capsys):
    write(tmp_path, "mod/main.tf", 'resource "aws_s3_bucket" "raw" {\n  bucket = "x"\n}\n')
    assert check.main(["check", str(tmp_path)]) == 1
    assert "s3-public-access" in capsys.readouterr().out
    assert check.main(["check", str(ROOT / "modules")]) == 0
