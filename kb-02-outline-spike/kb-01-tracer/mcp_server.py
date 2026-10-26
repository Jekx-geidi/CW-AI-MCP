"""KB-01 tracer bullet MCP server: search_knowledge + get_document.

Thinnest possible slice: client scope is hard-coded (one test client), ranking
is full-text only (the pgvector embedding column exists but isn't used for
ranking yet — real embeddings and hybrid ranking are KB-06's job).
"""
import os

import psycopg2
import psycopg2.extras
from mcp.server.mcpserver import MCPServer

KB_DB_URL = os.environ.get("KB_DB_URL", "postgresql://kb:kb@localhost:5433/kb")
CLIENT_SCOPE = "tracer-test-client"

mcp = MCPServer("kb-01-tracer")


def _connect():
    return psycopg2.connect(KB_DB_URL)


@mcp.tool()
def search_knowledge(query: str) -> list[dict]:
    """Full-text search over the indexed knowledge base for this client, most relevant first."""
    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, url_id, title, frontmatter,
                       ts_rank(search_vector, plainto_tsquery('english', %s)) AS rank
                FROM knowledge_document
                WHERE client = %s
                  AND search_vector @@ plainto_tsquery('english', %s)
                ORDER BY rank DESC
                LIMIT 10
                """,
                (query, CLIENT_SCOPE, query),
            )
            return cur.fetchall()
    finally:
        conn.close()


@mcp.tool()
def get_document(id: str) -> dict:
    """Fetch a single knowledge document's full text and metadata by its id."""
    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, url_id, title, text, frontmatter
                FROM knowledge_document
                WHERE id = %s AND client = %s
                """,
                (id, CLIENT_SCOPE),
            )
            row = cur.fetchone()
            if row is None:
                return {"error": f"no document {id} found for client {CLIENT_SCOPE}"}
            return row
    finally:
        conn.close()


if __name__ == "__main__":
    mcp.run(transport="stdio")
