"""Receive a signed release bundle; never execute the installer or log its URL."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPO = "Recicle-Metales/erp-recicle-releases"
API = "https://api.github.com/repos/" + REPO
MAX_BYTES = 512 * 1024 * 1024


def api(method, path, body=None, binary=None):
    url = path if path.startswith("https://") else API + path
    if not (url.startswith(API + "/") or url.startswith("https://uploads.github.com/repos/" + REPO + "/")):
        raise ValueError("Invalid GitHub API destination")
    headers = {"Authorization": "Bearer " + os.environ["GH_TOKEN"],
               "User-Agent": "recicle-release", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    if binary:
        with Path(binary).open("rb") as source:
            headers.update({"Content-Type": "application/octet-stream",
                            "Content-Length": str(Path(binary).stat().st_size)})
            request = urllib.request.Request(url, data=source, headers=headers, method=method)
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.load(response)
    data = None if body is None else json.dumps(body).encode()
    headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=45) as response:
        data = response.read()
        return json.loads(data) if data else None


def context():
    payload = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())["client_payload"]
    edition, version = payload["edition"], payload["version"]
    request_id, digest = payload["request_id"], payload["bundle_sha256"]
    if edition not in ("Bascula", "Embarques") or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Invalid edition/version")
    if not re.fullmatch(r"\d+-\d+-(bascula|embarques)", request_id) or not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("Invalid request/digest")
    if not isinstance(payload.get("verify_only"), bool):
        raise ValueError("Invalid verification mode")
    return payload


def installer(payload):
    prefix = "ERP-Recicle-Embarques-Setup" if payload["edition"] == "Embarques" else "ERP-Recicle-Setup"
    return Path("installer/output") / f"{prefix}-{payload['version']}.exe"


def allowed_name(name, payload):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != name:
        return False
    if name == installer(payload).as_posix():
        return True
    return payload["edition"] == "Bascula" and re.fullmatch(r"artifacts/label-previews/[A-Za-z0-9_.-]+\.pdf", name) is not None


class SameHostRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        old = urllib.parse.urlsplit(request.full_url)
        new = urllib.parse.urlsplit(newurl)
        if new.scheme != "https" or new.hostname != old.hostname:
            raise ValueError("Unexpected bundle redirect")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def receive(payload):
    url = payload["bundle_url"]
    print("::add-mask::" + url, flush=True)
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not (parsed.hostname or "").endswith(".neon.tech") or parsed.username or parsed.password:
        raise ValueError("Invalid private storage URL")
    digest = payload["bundle_sha256"]
    with tempfile.TemporaryDirectory() as folder:
        archive = Path(folder) / "bundle.zip"
        opener = urllib.request.build_opener(SameHostRedirect())
        with opener.open(url, timeout=180) as source, archive.open("wb") as target:
            total = 0
            while chunk := source.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_BYTES:
                    raise ValueError("Bundle too large")
                target.write(chunk)
        with archive.open("rb") as source:
            actual = hashlib.file_digest(source, "sha256").hexdigest()
        if actual != digest:
            raise ValueError("Bundle SHA-256 does not match the build runner")
        with zipfile.ZipFile(archive) as source:
            entries = source.infolist()
            names = [entry.filename for entry in entries]
            if len(names) != len(set(name.lower() for name in names)) or len(names) > 100:
                raise ValueError("Duplicate or excessive bundle entries")
            if sum(entry.file_size for entry in entries) > MAX_BYTES:
                raise ValueError("Uncompressed bundle too large")
            if not all(allowed_name(name, payload) for name in names):
                raise ValueError("Unexpected bundle file")
            if installer(payload).as_posix() not in names:
                raise ValueError("Missing installer")
            if payload["edition"] == "Bascula" and sum(name.endswith(".pdf") for name in names) < 3:
                raise ValueError("Missing label previews")
            for name in names:
                target = Path(name)
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(name) as entry, target.open("wb") as output:
                    import shutil
                    shutil.copyfileobj(entry, output)
    path = installer(payload)
    if path.stat().st_size < 100000:
        raise ValueError("Installer too small")
    with path.open("rb") as source:
        print(f"Verified {path.name}: {path.stat().st_size} bytes; SHA256={hashlib.file_digest(source, 'sha256').hexdigest()}")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"edition={payload['edition']}\nversion={payload['version']}\nverify_only={str(payload['verify_only']).lower()}\n")


def probe(payload):
    path = installer(payload)
    with path.open("rb") as source:
        expected = "sha256:" + hashlib.file_digest(source, "sha256").hexdigest()
    tag = "automation-probe-" + payload["request_id"]
    release = api("POST", "/releases", {"tag_name": tag, "target_commitish": "main",
        "name": "Private transfer verification", "draft": True, "prerelease": True})
    release_id = release["id"]
    try:
        upload = release["upload_url"].split("{")[0] + "?name=" + urllib.parse.quote(path.name)
        asset = api("POST", upload, binary=path)
        if asset.get("state") != "uploaded" or asset.get("digest") != expected or asset.get("size") != path.stat().st_size:
            raise ValueError("Probe asset digest or size mismatch")
        print(f"GitHub upload verified: {path.name}; {asset['size']} bytes; {asset['digest']}", flush=True)
    finally:
        # Only remove the disposable, unpublished release made by this test.
        existing = api("GET", f"/releases/{release_id}")
        if existing.get("draft") is True and existing.get("tag_name") == tag:
            api("DELETE", f"/releases/{release_id}")


def status(payload):
    result = {"request_id": payload["request_id"], "edition": payload["edition"],
              "version": payload["version"], "bundle_sha256": payload["bundle_sha256"],
              "verify_only": payload["verify_only"],
              "status": "success" if os.environ["JOB_STATUS"] == "success" else "failure",
              "run_url": f"https://github.com/{REPO}/actions/runs/{os.environ['GITHUB_RUN_ID']}"}
    path = "/contents/publication-status/" + payload["request_id"] + ".json"
    body = {"message": "Record release publication result",
            "content": base64.b64encode(json.dumps(result, indent=2).encode()).decode(), "branch": "main"}
    try:
        body["sha"] = api("GET", path)["sha"]
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    api("PUT", path, body)
    print(f"Recorded publication result: {result['status']}", flush=True)


if __name__ == "__main__":
    try:
        mode = argparse.ArgumentParser()
        mode.add_argument("mode", choices=("receive", "probe", "status"))
        args = mode.parse_args()
        payload = context()
        {"receive": receive, "probe": probe, "status": status}[args.mode](payload)
    except Exception as error:
        print(f"::error::{type(error).__name__}: release operation failed; signed URLs and credentials omitted.", flush=True)
        sys.exit(1)
