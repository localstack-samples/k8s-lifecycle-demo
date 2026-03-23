import os
import socket
import threading
from flask import Flask, jsonify

app = Flask(__name__)

_lock = threading.Lock()
_hit_count = 0

POD_NAME  = os.environ.get("POD_NAME",  socket.gethostname())
NODE_NAME = os.environ.get("NODE_NAME", "unknown")


@app.route("/")
def index():
    global _hit_count
    with _lock:
        _hit_count += 1
        count = _hit_count
    return jsonify({
        "hits":    count,
        "pod":     POD_NAME,
        "node":    NODE_NAME,
        "message": f"Hello from pod {POD_NAME} on node {NODE_NAME} — hit #{count}",
    })


@app.route("/health")
def health():
    return jsonify({"status": "ok", "pod": POD_NAME}), 200


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
