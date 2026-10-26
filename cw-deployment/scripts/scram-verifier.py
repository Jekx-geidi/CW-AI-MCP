"""Print a PostgreSQL SCRAM-SHA-256 password verifier for a password read from stdin.

Lets supabase-roles.sql set role passwords with
    ALTER ROLE ... PASSWORD 'SCRAM-SHA-256$4096:...'
so the plaintext never reaches the server, its statement log, or pg_stat_statements
(same thing psql's \\password does, but non-interactive).

    python3 -I scripts/scram-verifier.py < secrets/cw_agent_password

Standard library only. Output is a single line. The verifier is still sensitive
(offline brute-force target): treat it like a password hash.
"""
import base64
import hashlib
import hmac
import os
import sys

ITERATIONS = 4096  # PostgreSQL default (scram_iterations)


def verifier(password: str, salt: bytes | None = None, iterations: int = ITERATIONS) -> str:
    salt = salt or os.urandom(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode("ascii")
    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def main() -> int:
    password = sys.stdin.read().rstrip("\r\n")
    if len(password) < 24:
        print("refusing: password shorter than 24 characters", file=sys.stderr)
        return 1
    print(verifier(password))
    return 0


if __name__ == "__main__":
    sys.exit(main())
