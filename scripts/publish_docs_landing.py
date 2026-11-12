"""Update only gh-pages/index.html; never replace language/version trees."""
import base64
import json
from pathlib import Path
import subprocess

endpoint = "repos/AtelierArith/RustCall.jl/contents/index.html"
existing = json.loads(subprocess.check_output([
    "gh", "api", endpoint + "?ref=gh-pages"
]))
content = base64.b64encode(Path("docs/landing.html").read_bytes()).decode()
if existing["content"].replace("\n", "") != content:
    subprocess.run([
        "gh", "api", "--method", "PUT", endpoint, "--input", "-"
    ], input=json.dumps({
        "message": "Update documentation language landing page",
        "branch": "gh-pages", "sha": existing["sha"], "content": content,
    }), text=True, check=True)
