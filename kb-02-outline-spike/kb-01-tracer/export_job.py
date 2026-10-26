"""KB-01 tracer bullet: Outline webhook -> export -> frontmatter -> GitLab commit -> index.

Thinnest possible slice (per the ticket): hand-populated metadata row, no real
embedding model, no RLS, no client parameter on the eventual MCP tools (scope
is hard-coded here to one test client). Throwaway quality is fine.
"""
import http.server
import json
import os
import time
import urllib.parse
import urllib.request
import base64
import hashlib

import psycopg2

OUTLINE_URL = os.environ["OUTLINE_URL"]
OUTLINE_API_KEY = os.environ["OUTLINE_API_KEY"]
KB_DB_URL = os.environ["KB_DB_URL"]
GITLAB_TOKEN = os.environ.get("GITLAB_TOKEN", "")
GITLAB_PROJECT = os.environ["GITLAB_PROJECT"]
GITLAB_BASE = "https://foundry.scale.au/api/v4"

# Hand-populated metadata row (KB-04's real schema is deferred; this is a
# tracer, so the row is just hardcoded here rather than built from a UI).
METADATA_ROW = {
    "type": "SOP",
    "scope": "single-client",
    "client": "tracer-test-client",
    "service": "kb-01-tracer",
    "owner": "reil@geidi.com",
    "verified_by": None,
    "last_verified": None,
}


def outline_call(method, body):
    req = urllib.request.Request(
        f"{OUTLINE_URL}/api/{method}",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {OUTLINE_API_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def gitlab_commit(path_in_repo, content, commit_message):
    if not GITLAB_TOKEN:
        print("  ! GITLAB_TOKEN not set, skipping commit (logging content instead)")
        print(content[:300])
        return "skipped-no-token"
    enc_project = urllib.parse.quote(GITLAB_PROJECT, safe="")
    enc_path = urllib.parse.quote(path_in_repo, safe="")
    url = f"{GITLAB_BASE}/projects/{enc_project}/repository/files/{enc_path}"
    body = {
        "branch": "main",
        "content": content,
        "commit_message": commit_message,
    }
    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN, "Content-Type": "application/json"}
    data = json.dumps(body).encode()
    # Try update first (PUT); if the file doesn't exist yet, create it (POST).
    for method in ("PUT", "POST"):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if method == "PUT" and e.code == 400:
                continue  # file doesn't exist yet, fall through to POST
            print(f"  ! GitLab {method} failed: {e.code} {e.read().decode()[:300]}")
    return None


def placeholder_embedding(text):
    """8-dim deterministic pseudo-embedding from a hash, just to exercise the
    pgvector column end to end. Real embedding model is KB-06's job."""
    h = hashlib.sha256(text.encode()).digest()
    return [round((b / 255.0) * 2 - 1, 4) for b in h[:8]]


def index_document(doc_id, url_id, title, markdown_text, frontmatter):
    conn = psycopg2.connect(KB_DB_URL)
    try:
        with conn, conn.cursor() as cur:
            embedding = placeholder_embedding(markdown_text)
            cur.execute(
                """
                INSERT INTO knowledge_document (id, url_id, title, text, frontmatter, embedding, client)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (id) DO UPDATE SET
                    url_id = EXCLUDED.url_id,
                    title = EXCLUDED.title,
                    text = EXCLUDED.text,
                    frontmatter = EXCLUDED.frontmatter,
                    embedding = EXCLUDED.embedding,
                    updated_at = now()
                """,
                (doc_id, url_id, title, markdown_text, json.dumps(frontmatter), embedding, frontmatter["client"]),
            )
    finally:
        conn.close()


def process_document(doc_id):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] processing document {doc_id}")

    info = outline_call("documents.info", {"id": doc_id})["data"]
    title = info["title"]
    url_id = info["urlId"]

    exported = outline_call("documents.export", {"id": doc_id})
    markdown_text = exported["data"] if isinstance(exported.get("data"), str) else info["text"]

    frontmatter = dict(METADATA_ROW)
    frontmatter["id"] = doc_id

    fm_lines = ["---"]
    for k, v in frontmatter.items():
        fm_lines.append(f"{k}: {json.dumps(v)}")
    fm_lines.append("---")
    full_content = "\n".join(fm_lines) + "\n\n" + markdown_text

    repo_path = f"docs/{url_id}.md"
    result = gitlab_commit(repo_path, full_content, f"KB-01 tracer: export {title} ({doc_id})")
    print(f"  gitlab commit result: {result if not isinstance(result, dict) else result.get('file_path', result)}")

    index_document(doc_id, url_id, title, markdown_text, frontmatter)
    print(f"  indexed into kb-index-postgres (client={frontmatter['client']})")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
        try:
            payload = json.loads(body)
            event = payload.get("event")
            if event in ("documents.publish", "documents.update"):
                doc_id = payload["payload"]["id"]
                process_document(doc_id)
        except Exception as e:
            print(f"  ! error processing webhook: {e}")

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    print("KB-01 export job listening on :9100 for Outline webhooks...")
    http.server.HTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
