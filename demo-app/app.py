import os

from flask import Flask, jsonify

app = Flask(__name__)

# La version est injectée au moment du build de l'image (voir le Dockerfile).
VERSION = os.environ.get("APP_VERSION", "dev")


@app.get("/")
def index():
    return f"demo-app version {VERSION} - ArthurLab\n"


@app.get("/health")
def health():
    return jsonify(status="ok", version=VERSION)
