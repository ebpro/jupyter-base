"""Registry-upload body-transit tests for scripts/stage-toolcache.sh.

WHY THIS FILE EXISTS. CI run 39018544362 failed 12/12 toolcache pushes with
Harbor core logging, once per repository::

    http: proxy error: net/http: HTTP/1.x transport connection broken:
    http: ContentLength=2 with Body length 0

The 2 bytes are the ``{}`` OCI config blob: the blob-upload *PUT* reached the
registry with a declared Content-Length and no body. The healthy pre-flight
(GET /v2/ -> 200, scoped pull,push token, HEAD manifest -> 404) excluded auth
and repository-name shape; the defect was the invocation form
``-X PUT --data-binary "@$file"``, which does not guarantee the body is
transmitted across redirect hops (registries finalize uploads with a 307
bounce to storage). The fix uploads with ``-T "$file"`` plus ``-H 'Expect:'``
and ``--fail-with-body``.

WHAT THESE TESTS RUN. The real shipped code: ``push_blob`` and
``push_manifest`` are extracted VERBATIM from scripts/stage-toolcache.sh
(same convention as tests/test_download_direct_integrity_gate.py) and executed
in a bash subprocess against a threaded stdlib fake registry on 127.0.0.1.
The real system ``curl`` is used — the property under test is exactly what
curl puts on the wire, so stubbing curl would test nothing. No external
network: every socket is loopback.

THE FAKE ENFORCES THE HARBOR-CORE CHECK on every finalized PUT:
``received_body_len == Content-Length`` (else 502 with the same error text),
and ``sha256(body) == digest`` when the URL carries one (else 400
DIGEST_INVALID). An upload that arrives as an empty PUT therefore FAILS here
loudly — unlike a lenient server that would silently accept 0 bytes.

MEASURED curl behaviour (8.7.1, probed while writing this test) that shapes
the assertions:
  * direct PUT: both forms transmit the body;
  * 307 hop (the OCI-spec redirect): both forms re-send the body — the CI
    loss on the runner's curl 8.5.0 (libcurl fixed exactly this
    redirect/Expect/100-continue resend family in 8.6.0: #12411, #12549) is
    NOT reproducible with the local binary and is deliberately NOT asserted;
  * 302/303 hops: ``-X PUT --data-binary`` DETERMINISTICALLY arrives with no
    body (25/25 runs; curl discards the -d payload while -X keeps the method)
    — the same body-loss shape as the incident, reproducible hermetically;
    ``-T`` re-reads the file and arrives byte-exact (10/10 runs).
So the "fails against the pre-fix form" direction is proven three ways:
(1) behaviourally, against the 302 body-loss repro;
(2) behaviourally, on diagnosability (``-f`` hides the registry body,
    ``--fail-with-body`` prints it);
(3) statically, via the invocation-form contract, which is curl-version
    independent and flags the embedded pre-fix function text.
"""

import hashlib
import re
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "stage-toolcache.sh"

# --- bash >= 4 resolution (macOS /bin/bash is 3.2); same approach as
# tests/test_download_direct_integrity_gate.py --------------------------------
_BASH_CANDIDATES = [
    "/opt/homebrew/bin/bash",
    "/usr/local/bin/bash",
    "/bin/bash",
]


def _bash_major(path):
    try:
        out = subprocess.run(
            [path, "-c", 'echo "${BASH_VERSINFO[0]}"'],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return int(out.stdout.strip())
    except (ValueError, OSError):
        return 0


def _resolve_bash():
    found = shutil.which("bash")
    ordered = _BASH_CANDIDATES + ([found] if found and found not in _BASH_CANDIDATES else [])
    for cand in ordered:
        if Path(cand).is_file() and _bash_major(cand) >= 4:
            return cand
    return ""


BASH = _resolve_bash()
_HAVE_CURL = shutil.which("curl")

if not BASH:
    pytest.skip("no bash >= 4 found; stage-toolcache.sh requires bash 4+", allow_module_level=True)
if not _HAVE_CURL:
    pytest.skip("curl is the unit under test's transport; not installed", allow_module_level=True)
CURL = str(_HAVE_CURL)

# Payloads mirror the real push shapes: the 2-byte config blob and a
# >1KB (Expect-threshold) deterministic "archive" body.
CFG_BYTES = b"{}"
LAYER_BYTES = bytes((i * 7 + 11) % 256 for i in range(6144))
MANIFEST_BYTES = b'{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}'
SENTINEL_TOKEN = "sentiNEL-bearer-token-must-never-be-logged"
REGISTRY_ERROR_BODY = '{"errors":[{"code":"UNKNOWN","message":"simulated harbor-core proxy breakage"}]}'


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _extract_function(src, name):
    """Return `name() { ... }` verbatim — up to the first column-0 `}`."""
    lines = src.splitlines(keepends=True)
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f"{name}()"):
            start = i
            break
    assert start is not None, f"function {name}() not found in {SCRIPT}"
    end = None
    for i in range(start + 1, len(lines)):
        if lines[i].rstrip("\n") == "}":
            end = i
            break
    assert end is not None, f"unterminated function {name}() in {SCRIPT}"
    return "".join(lines[start : end + 1])


# The exact pre-fix upload stanza (the shape shipped until this fix; kept
# verbatim from git as the "buggy reference" the inversion tests must flag).
PREFIX_PUSH_BLOB = '''push_blob() { # repo token file digest
  local repo="$1" tok="$2" file="$3" digest="$4" loc sep
  loc="$(curl -fsSL -X POST -D - -o /dev/null \\
    -H "Authorization: Bearer $tok" \\
    -H 'Content-Type: application/octet-stream' \\
    "$HARBOR_BASE/v2/$repo/blobs/uploads/" | tr -d '\\r' \\
    | awk 'tolower($1)=="location:"{print $2}')"
  [ -n "$loc" ] || { err "$repo: no upload location from POST /blobs/uploads/"; return 1; }
  case "$loc" in
    http*) : ;;
    /*)    loc="$HARBOR_BASE$loc" ;;
    *)     loc="$HARBOR_BASE/$loc" ;;
  esac
  sep='?'; case "$loc" in *\\?*) sep='&' ;; esac
  curl -fsSL -X PUT --data-binary "@$file" \\
    -H "Authorization: Bearer $tok" \\
    "${loc}${sep}digest=${digest}" >/dev/null
}'''


class _FakeRegistry:
    """Loopback OCI-ish registry enforcing the Harbor-core body check.

    redirect: None | 302 | 307 — the status the upload-finalize PUT's first
    hop answers with (Location = same path + &hop=1, like a storage bounce).
    always502: every finalized PUT answers 502 + REGISTRY_ERROR_BODY.
    location_query: whether the 202 Location carries a ?_state= query
    (exercises the script's '?'/'&' digest-separator logic).
    """

    def __init__(self, redirect=None, always502=False, location_query=True):
        self.requests = []  # dicts: method/path/headers/body/note
        self.redirect = redirect
        self.always502 = always502
        self.location_query = location_query
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format, *args):  # keep pytest output clean
                pass

            def _drain(self):
                cl = self.headers.get("Content-Length")
                body = b""
                if cl:
                    need = int(cl)
                    while len(body) < need:
                        chunk = self.rfile.read(need - len(body))
                        if not chunk:
                            break
                        body += chunk
                return cl, body

            def _record(self, cl, body, note):
                outer.requests.append(
                    {
                        "method": self.command,
                        "path": self.path,
                        "content_length": cl,
                        "body": body,
                        "expect": self.headers.get("Expect"),
                        "content_type": self.headers.get("Content-Type"),
                        "authorization": self.headers.get("Authorization"),
                        "note": note,
                    }
                )

            def _send(self, code, payload=b"", extra=None):
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                if payload:
                    self.wfile.write(payload)

            def do_POST(self):
                cl, body = self._drain()
                self._record(cl, body, "upload-init")
                if self.path.endswith("/blobs/uploads/"):
                    loc = "/v2/testrepo/blobs/uploads/fake-uuid-1"
                    if outer.location_query:
                        loc += "?_state=opaque"
                    self._send(202, extra={"Location": loc})
                else:
                    self._send(404, b'{"errors":[{"code":"NOT_FOUND"}]}')

            def do_PUT(self):
                cl, body = self._drain()
                if outer.redirect and "hop=1" not in self.path:
                    self._record(cl, body, f"hop0->{outer.redirect}")
                    sep = "&" if "?" in self.path else "?"
                    self.send_response(outer.redirect)
                    self.send_header("Location", self.path + sep + "hop=1")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self._record(cl, body, "final")
                if outer.always502:
                    self._send(502, REGISTRY_ERROR_BODY.encode())
                    return
                n = int(cl) if cl else 0
                if n != len(body):
                    # The Harbor-core wire signature, reproduced verbatim.
                    self._send(
                        502,
                        json_error(
                            "UNKNOWN",
                            "http: proxy error: net/http: HTTP/1.x transport "
                            f"connection broken: http: ContentLength={n} "
                            f"with Body length {len(body)}",
                        ),
                    )
                    return
                m = re.search(r"[?&]digest=sha256:([0-9a-f]{64})", self.path)
                if m and _sha256(body) != m.group(1):
                    self._send(
                        400,
                        json_error(
                            "DIGEST_INVALID", "provided digest did not match uploaded content"
                        ),
                    )
                    return
                self._send(201, b'{"ok":true}')

        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._srv.daemon_threads = True
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()

    @property
    def url(self):
        addr = self._srv.server_address
        return f"http://{addr[0]}:{addr[1]}"

    def put_hops(self):
        return [r for r in self.requests if r["method"] == "PUT"]

    def final_puts(self):
        return [r for r in self.put_hops() if r["note"] == "final"]

    def shutdown(self):
        self._srv.shutdown()
        self._srv.server_close()


def json_error(code, message):
    return f'{{"errors":[{{"code":"{code}","message":"{message}"}}]}}'.encode()


def _run_driver(tmp_path, funcs, call, reg_url, name="driver"):
    """Run `funcs` (verbatim script code) + `call` under bash, real curl."""
    driver = tmp_path / f"{name}.sh"
    driver.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        f'HARBOR_BASE="{reg_url}"\n'
        "err() { echo \"   ❌ $*\" >&2; }\n"
        + funcs
        + "\n"
        + call
        + "\n"
    )
    driver.chmod(0o755)
    return subprocess.run(
        [BASH, str(driver)], capture_output=True, text=True, timeout=60, check=False
    )


@pytest.fixture()
def registry(request):
    reg = _FakeRegistry()
    request.addfinalizer(reg.shutdown)
    return reg


def _payload(tmp_path, name, data):
    p = tmp_path / name
    p.write_bytes(data)
    return p


class TestToolchainProbe:
    def test_local_curl_supports_fail_with_body(self):
        # --fail-with-body needs curl >= 7.76; the shipped form depends on it.
        # An unsupported option exits 2 with "option --fail-with-body ... not
        # known"; a supported one reaches the connection stage instead.
        proc = subprocess.run(
            [CURL, "--fail-with-body", "http://127.0.0.1:1/"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        assert "not known" not in proc.stderr, proc.stderr


class TestBlobBodyTransit:
    """The property from the incident: received bytes == Content-Length."""

    def test_small_config_blob_exact_bytes_direct(self, tmp_path, registry):
        cfg = _payload(tmp_path, "cfg", CFG_BYTES)
        proc = _run_driver(
            tmp_path,
            _extract_function(SCRIPT.read_text(), "push_blob"),
            f'push_blob testrepo "{SENTINEL_TOKEN}" "{cfg}" "sha256:{_sha256(CFG_BYTES)}"',
            registry.url,
        )
        assert proc.returncode == 0, proc.stderr
        finals = registry.final_puts()
        assert len(finals) == 1
        rec = finals[0]
        assert rec["body"] == CFG_BYTES                      # the bytes arrive...
        assert rec["content_length"] == str(len(CFG_BYTES))  # ...exactly as declared
        assert "&digest=sha256:" in rec["path"]              # sep logic vs ?_state= Location
        assert all(r["expect"] is None for r in registry.put_hops())  # Expect suppressed

    def test_large_layer_exact_bytes_direct(self, tmp_path, registry):
        lay = _payload(tmp_path, "layer", LAYER_BYTES)
        proc = _run_driver(
            tmp_path,
            _extract_function(SCRIPT.read_text(), "push_blob"),
            f'push_blob testrepo "{SENTINEL_TOKEN}" "{lay}" "sha256:{_sha256(LAYER_BYTES)}"',
            registry.url,
        )
        assert proc.returncode == 0, proc.stderr
        rec = registry.final_puts()[-1]
        assert rec["body"] == LAYER_BYTES
        assert rec["content_length"] == str(len(LAYER_BYTES))

    def test_location_without_query_uses_question_separator(self, tmp_path):
        reg = _FakeRegistry(location_query=False)
        try:
            cfg = _payload(tmp_path, "cfg", CFG_BYTES)
            proc = _run_driver(
                tmp_path,
                _extract_function(SCRIPT.read_text(), "push_blob"),
                f'push_blob testrepo "{SENTINEL_TOKEN}" "{cfg}" "sha256:{_sha256(CFG_BYTES)}"',
                reg.url,
            )
            assert proc.returncode == 0, proc.stderr
            assert "?digest=sha256:" in reg.final_puts()[-1]["path"]
        finally:
            reg.shutdown()


class TestRedirectBodyLoss:
    """The body-loss path and its fix, measured against real curl."""

    @pytest.mark.parametrize("redirect", [302, 307])
    def test_shipped_form_delivers_exact_body_through_redirect(self, tmp_path, redirect):
        reg = _FakeRegistry(redirect=redirect)
        try:
            lay = _payload(tmp_path, "layer", LAYER_BYTES)
            proc = _run_driver(
                tmp_path,
                _extract_function(SCRIPT.read_text(), "push_blob"),
                f'push_blob testrepo "{SENTINEL_TOKEN}" "{lay}" "sha256:{_sha256(LAYER_BYTES)}"',
                reg.url,
            )
            assert proc.returncode == 0, proc.stderr
            final = reg.final_puts()[-1]
            assert final["body"] == LAYER_BYTES
            assert final["content_length"] == str(len(LAYER_BYTES))
        finally:
            reg.shutdown()

    def test_prefix_form_loses_body_through_redirect(self, tmp_path):
        # Measured on curl 8.7.1: `-X PUT --data-binary` crosses a 302 with
        # the payload discarded while -X keeps the method PUT — an empty PUT
        # the fake rejects exactly like Harbor core rejected the CI pushes
        # (`ContentLength=N with Body length 0`). curl 8.5.0 on the CI runner
        # lost the body while KEEPING the Content-Length header; the shipped
        # `-T` form re-reads the file and is intact under both.
        reg = _FakeRegistry(redirect=302)
        try:
            lay = _payload(tmp_path, "layer", LAYER_BYTES)
            proc = _run_driver(
                tmp_path,
                PREFIX_PUSH_BLOB,
                f'push_blob testrepo "{SENTINEL_TOKEN}" "{lay}" "sha256:{_sha256(LAYER_BYTES)}"',
                reg.url,
                name="prefix",
            )
            finals = reg.final_puts()
            assert finals, "pre-fix form never reached the finalize hop at all"
            assert finals[-1]["body"] == b""       # the body-loss signature
            assert finals[-1]["content_length"] in (None, "0") or int(
                finals[-1]["content_length"]
            ) != len(finals[-1]["body"])
            assert proc.returncode != 0            # and it FAILS, loudly
        finally:
            reg.shutdown()


class TestManifestUpload:
    def test_manifest_put_preserves_content_type_and_body(self, tmp_path, registry):
        man = _payload(tmp_path, "manifest", MANIFEST_BYTES)
        proc = _run_driver(
            tmp_path,
            _extract_function(SCRIPT.read_text(), "push_manifest"),
            f'push_manifest testrepo "{SENTINEL_TOKEN}" "{man}" "sha256-{_sha256(LAYER_BYTES)}"',
            registry.url,
        )
        assert proc.returncode == 0, proc.stderr
        rec = registry.final_puts()[-1]
        assert rec["body"] == MANIFEST_BYTES
        assert rec["content_length"] == str(len(MANIFEST_BYTES))
        # Required for a manifest PUT — must survive the -T conversion:
        assert rec["content_type"] == "application/vnd.oci.image.manifest.v1+json"
        assert rec["path"] == f"/v2/testrepo/manifests/sha256-{_sha256(LAYER_BYTES)}"
        assert all(r["expect"] is None for r in registry.put_hops())


class TestDiagnosability:
    """The next failure must be self-explaining, not a bare `(22)`."""

    def test_registry_error_body_is_printed_by_shipped_form(self, tmp_path):
        reg = _FakeRegistry(always502=True)
        try:
            cfg = _payload(tmp_path, "cfg", CFG_BYTES)
            proc = _run_driver(
                tmp_path,
                _extract_function(SCRIPT.read_text(), "push_blob"),
                f'push_blob testrepo "{SENTINEL_TOKEN}" "{cfg}" "sha256:{_sha256(CFG_BYTES)}"',
                reg.url,
            )
            assert proc.returncode == 1  # push_blob keeps the return-1 contract
            assert REGISTRY_ERROR_BODY in proc.stderr  # the registry's own words
        finally:
            reg.shutdown()

    def test_prefix_form_hides_the_registry_body(self, tmp_path):
        # The old `-f` + >/dev/null: same 502, same server, no explanation —
        # this is the (22)-only CI output the fix removes.
        reg = _FakeRegistry(always502=True)
        try:
            cfg = _payload(tmp_path, "cfg", CFG_BYTES)
            proc = _run_driver(
                tmp_path,
                PREFIX_PUSH_BLOB,
                f'push_blob testrepo "{SENTINEL_TOKEN}" "{cfg}" "sha256:{_sha256(CFG_BYTES)}"',
                reg.url,
                name="prefix",
            )
            assert proc.returncode != 0
            assert REGISTRY_ERROR_BODY not in proc.stderr + proc.stdout
        finally:
            reg.shutdown()

    def test_bearer_token_never_appears_in_failure_output(self, tmp_path):
        reg = _FakeRegistry(always502=True)
        try:
            cfg = _payload(tmp_path, "cfg", CFG_BYTES)
            proc = _run_driver(
                tmp_path,
                _extract_function(SCRIPT.read_text(), "push_blob"),
                f'push_blob testrepo "{SENTINEL_TOKEN}" "{cfg}" "sha256:{_sha256(CFG_BYTES)}"',
                reg.url,
            )
            assert proc.returncode == 1
            assert SENTINEL_TOKEN not in proc.stdout
            assert SENTINEL_TOKEN not in proc.stderr
        finally:
            reg.shutdown()


class TestInvocationFormContract:
    """Static, curl-version-independent pins of the fixed form — and proof
    the same checks FLAG the pre-fix invocation (the DoD inversion)."""

    _FORBIDDEN = ("--data-binary", "-X PUT", ">/dev/null")
    _REQUIRED = ("-T ", "--fail-with-body", "-H 'Expect:'", '-H "Authorization: Bearer')

    @staticmethod
    def _code_only(src):
        # Scan EXECUTABLE lines only: the functions' own rationale comments
        # quote the defective form they replaced.
        return "\n".join(
            ln for ln in src.splitlines() if not ln.lstrip().startswith("#")
        )

    @pytest.mark.parametrize("func", ["push_blob", "push_manifest"])
    def test_shipped_form_required_and_forbidden(self, func):
        src = self._code_only(_extract_function(SCRIPT.read_text(), func))
        for needle in self._REQUIRED:
            assert needle in src, f"{func}: fixed-form marker {needle!r} missing"
        for needle in self._FORBIDDEN:
            assert needle not in src, f"{func}: defective marker {needle!r} present"

    def test_contract_flags_the_prefix_form(self):
        # The same battery MUST reject the buggy reference form — otherwise
        # the pins above would be vacuous.
        src = self._code_only(PREFIX_PUSH_BLOB)
        violations = [n for n in self._FORBIDDEN if n in src] + [
            n for n in ("-T ", "--fail-with-body", "-H 'Expect:'") if n not in src
        ]
        assert violations, "form contract has no discriminating power"
