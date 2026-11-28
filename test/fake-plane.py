"""A tiny in-memory stand-in for the parts of Plane's REST API that
pc/setup-plane.ps1 uses. For tests only.

Usage: python -I test/fake-plane.py <token>
Prints the port it listens on (127.0.0.1) as its first line.

Mirrors Plane 1.5.0 where the script depends on it: the X-Api-Key header, the
paginated list shape, default states created with a project, "default": true
moving the default, and 409 on a duplicate identifier / state / label name.
GET /_dump returns the whole store and POST /_count the number of writes, so
tests can check that plan mode changed nothing.
"""
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

TOKEN = sys.argv[1]
STORE = {"projects": []}   # each project: {id, name, identifier, states: [], labels: []}
WRITES = {"n": 0}
# Plane 1.5.0 Project.FORBIDDEN_IDENTIFIER_CHARS_PATTERN, checked on name and identifier
FORBIDDEN = r"^.*[&+,:;$^}{*=?@#|'<>.()%!-].*$"

DEFAULT_STATES = [
    ("Backlog", "backlog", True), ("Todo", "unstarted", False),
    ("In Progress", "started", False), ("Done", "completed", False),
    ("Cancelled", "cancelled", False),
]


def page(items):
    return {"results": items, "next_page_results": False, "next_cursor": "1000:1:0", "count": len(items)}


def public(obj):
    return {k: v for k, v in obj.items() if k not in ("states", "labels")}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def route(self, method):
        path = urlparse(self.path).path
        if path == "/_dump":
            return self.send(200, STORE)
        if path == "/_count":
            return self.send(200, {"writes": WRITES["n"]})
        if self.headers.get("X-Api-Key") != TOKEN:
            return self.send(401, {"detail": "Authentication credentials were not provided."})
        parts = [p for p in path.split("/") if p]
        # api v1 workspaces <slug> projects [<id> (states|labels) [<id>]]
        if parts[:3] != ["api", "v1", "workspaces"] or len(parts) < 5 or parts[4] != "projects":
            return self.send(404, {"detail": "not found"})
        rest = parts[5:]
        if method != "GET":
            WRITES["n"] += 1
        if not rest:
            if method == "GET":
                return self.send(200, page([public(p) for p in STORE["projects"]]))
            if method == "POST":
                b = self.body()
                ident = b.get("identifier", "").upper()
                if re.match(FORBIDDEN, b.get("name", "")):
                    return self.send(400, {"non_field_errors": ["Project name cannot contain special characters."]})
                if re.match(FORBIDDEN, ident):
                    return self.send(400, {"non_field_errors": ["Project identifier cannot contain special characters."]})
                if any(p["identifier"] == ident for p in STORE["projects"]):
                    return self.send(409, {"identifier": "The project identifier is already taken"})
                p = {"id": str(uuid.uuid4()), "name": b["name"], "identifier": ident, "labels": [],
                     "states": [{"id": str(uuid.uuid4()), "name": n, "group": g, "default": d, "color": "#000000"}
                                for n, g, d in DEFAULT_STATES]}
                STORE["projects"].append(p)
                return self.send(201, public(p))
        proj = next((p for p in STORE["projects"] if p["id"] == rest[0]), None)
        if proj is None or len(rest) < 2 or rest[1] not in ("states", "labels"):
            return self.send(404, {"detail": "not found"})
        kind = rest[1]
        items = proj[kind]
        if len(rest) == 2:
            if method == "GET":
                return self.send(200, page(items))
            if method == "POST":
                b = self.body()
                if any(i["name"].lower() == b["name"].lower() for i in items):
                    return self.send(409, {"error": f"{kind[:-1]} with the same name already exists"})
                item = {"id": str(uuid.uuid4()), **b}
                if kind == "states":
                    item.setdefault("default", False)
                    if item["default"]:
                        for i in items:
                            i["default"] = False
                items.append(item)
                return self.send(200, item)
        if len(rest) == 3 and method == "PATCH" and kind == "states":
            item = next((i for i in items if i["id"] == rest[2]), None)
            if item is None:
                return self.send(404, {"detail": "not found"})
            b = self.body()
            if b.get("default"):
                for i in items:
                    i["default"] = False
            item.update(b)
            return self.send(200, item)
        return self.send(405, {"detail": "method not allowed"})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
