"""Static guardrails for the Terraform in this repo, run in CI before `terraform plan`.

Parses HCL directly (python-hcl2), so it needs no AWS credentials and fails fast on a PR.
Each rule returns (file, resource address, message) violations.

    python policy/check.py            # whole repo
    python policy/check.py envs/prod  # one directory
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

import hcl2

REQUIRED_TAGS = {"Environment", "Owner", "CostCenter"}
OPEN_INGRESS_ALLOWED_PORTS = {80, 443}
ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Violation:
    file: str
    address: str
    rule: str
    message: str

    def __str__(self) -> str:
        return f"{self.file}: {self.address}: [{self.rule}] {self.message}"


@dataclass
class TfFile:
    path: Path
    doc: dict

    def resources(self, rtype: str | None = None) -> Iterable[tuple[str, str, dict]]:
        for block in self.doc.get("resource", []):
            for t, named in block.items():
                if rtype and t != rtype:
                    continue
                for name, body in named.items():
                    yield t, name, body

    def blocks(self, kind: str) -> list[dict]:
        return self.doc.get(kind, [])


def load(paths: Iterable[Path]) -> list[TfFile]:
    files = []
    for p in sorted(paths):
        with open(p, encoding="utf-8") as fh:
            files.append(TfFile(p, hcl2.load(fh)))
    return files


def _first(v):
    """python-hcl2 wraps nested blocks in lists; unwrap one level."""
    return v[0] if isinstance(v, list) and v else v


def _rel(p: Path) -> str:
    try:
        return p.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return p.as_posix()


# ---------------------------------------------------------------- rules

def rule_s3_public_access_block(files: list[TfFile]) -> list[Violation]:
    """Every bucket defined in a directory must have a public access block in that same directory."""
    out = []
    by_dir: dict[Path, list[TfFile]] = {}
    for f in files:
        by_dir.setdefault(f.path.parent, []).append(f)
    for d, fs in by_dir.items():
        blocked = {_first(b.get("bucket", "")) for f in fs for _, _, b in f.resources("aws_s3_bucket_public_access_block")}
        for f in fs:
            for _, name, _ in f.resources("aws_s3_bucket"):
                if not any(f"aws_s3_bucket.{name}." in str(b) for b in blocked):
                    out.append(Violation(_rel(f.path), f"aws_s3_bucket.{name}", "s3-public-access", "bucket has no aws_s3_bucket_public_access_block"))
    return out


def rule_s3_encryption(files: list[TfFile]) -> list[Violation]:
    return [
        Violation(_rel(f.path), f"aws_s3_bucket.{name}", "s3-encryption", "server_side_encryption_configuration missing")
        for f in files for _, name, body in f.resources("aws_s3_bucket")
        if "server_side_encryption_configuration" not in body
    ]


def rule_rds(files: list[TfFile]) -> list[Violation]:
    out = []
    for f in files:
        for _, name, body in f.resources("aws_db_instance"):
            addr = f"aws_db_instance.{name}"
            if body.get("storage_encrypted") is not True:
                out.append(Violation(_rel(f.path), addr, "rds-encryption", "storage_encrypted must be true"))
            if body.get("publicly_accessible") is not False:
                out.append(Violation(_rel(f.path), addr, "rds-private", "publicly_accessible must be explicitly false"))
            if "password" in body and not str(body["password"]).startswith("${random_password."):
                out.append(Violation(_rel(f.path), addr, "rds-password", "password must come from random_password, never a literal or variable"))
    return out


def _ports(rule: dict) -> range:
    lo, hi = int(rule.get("from_port", 0)), int(rule.get("to_port", 0))
    if str(rule.get("protocol")) == "-1":
        return range(0, 65536)
    return range(lo, hi + 1)


def rule_open_ingress(files: list[TfFile]) -> list[Violation]:
    """0.0.0.0/0 ingress is only allowed on 80/443 (the public load balancer)."""
    out = []
    for f in files:
        for _, name, body in f.resources("aws_security_group"):
            for ing in body.get("ingress", []):
                if "0.0.0.0/0" in (ing.get("cidr_blocks") or []):
                    bad = set(_ports(ing)) - OPEN_INGRESS_ALLOWED_PORTS
                    if bad:
                        out.append(Violation(_rel(f.path), f"aws_security_group.{name}", "open-ingress",
                                             f"0.0.0.0/0 ingress on ports {min(bad)}-{max(bad)}"))
        for _, name, body in f.resources("aws_security_group_rule"):
            if body.get("type") == "ingress" and "0.0.0.0/0" in (body.get("cidr_blocks") or []):
                if set(_ports(body)) - OPEN_INGRESS_ALLOWED_PORTS:
                    out.append(Violation(_rel(f.path), f"aws_security_group_rule.{name}", "open-ingress", "0.0.0.0/0 ingress"))
    return out


def rule_pinned_providers(files: list[TfFile]) -> list[Violation]:
    out = []
    for f in files:
        for tf in f.blocks("terraform"):
            for req in tf.get("required_providers", []):
                for prov, spec in req.items():
                    version = spec.get("version") if isinstance(spec, dict) else None
                    if not version or not (version.startswith("~>") or version.startswith("=")):
                        out.append(Violation(_rel(f.path), f"provider.{prov}", "pinned-provider", "use a ~> or = version constraint"))
    return out


def rule_env_backend_and_tags(files: list[TfFile]) -> list[Violation]:
    """Environment roots must use a locked, encrypted remote backend and define the required tags."""
    out = []
    env_files = [f for f in files if "envs" in f.path.parts]
    roots: dict[Path, list[TfFile]] = {}
    for f in env_files:
        roots.setdefault(f.path.parent, []).append(f)
    for d, fs in roots.items():
        backends = [b for f in fs for tf in f.blocks("terraform") for b in tf.get("backend", [])]
        s3 = [_first(b["s3"]) for b in backends if "s3" in b]
        where = _rel(d)
        if not s3:
            out.append(Violation(where, "terraform.backend", "remote-state", "environment must use the s3 backend"))
        else:
            cfg = s3[0]
            if cfg.get("encrypt") is not True or not cfg.get("dynamodb_table"):
                out.append(Violation(where, "terraform.backend", "remote-state", "backend needs encrypt = true and a dynamodb_table lock"))
        tag_keys: set[str] = set()
        for f in fs:
            for loc in f.blocks("locals"):
                if isinstance(loc.get("tags"), dict):
                    tag_keys |= set(loc["tags"].keys())
        missing = REQUIRED_TAGS - tag_keys
        if missing:
            out.append(Violation(where, "locals.tags", "required-tags", f"missing {sorted(missing)}"))
    return out


def rule_no_latest_images(files: list[TfFile]) -> list[Violation]:
    out = []
    for f in files:
        for mod in f.blocks("module"):
            for name, body in mod.items():
                image = body.get("image")
                if isinstance(image, str) and (image.endswith(":latest") or ":" not in image.split("/")[-1]):
                    out.append(Violation(_rel(f.path), f"module.{name}", "pinned-image", f"image {image!r} is not pinned"))
    return out


RULES: list[Callable[[list[TfFile]], list[Violation]]] = [
    rule_s3_public_access_block, rule_s3_encryption, rule_rds, rule_open_ingress,
    rule_pinned_providers, rule_env_backend_and_tags, rule_no_latest_images,
]


def check(paths: Iterable[Path]) -> list[Violation]:
    files = load(paths)
    return [v for rule in RULES for v in rule(files)]


def main(argv: list[str]) -> int:
    target = Path(argv[1]) if len(argv) > 1 else ROOT
    tf_files = [p for p in target.rglob("*.tf") if ".terraform" not in p.parts and "fixtures" not in p.parts]
    violations = check(tf_files)
    for v in violations:
        print(v)
    print(f"{len(tf_files)} files, {len(RULES)} rules, {len(violations)} violation(s)")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
