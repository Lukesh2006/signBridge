import json
import os
from pathlib import Path

import firebase_admin
from firebase_admin import auth as admin_auth
from firebase_admin import credentials


# Project root:
# backend/
# ├── firebase.json
# ├── firebase-admin.json
# └── app/
#     └── config/
#         └── firebase_admin_init.py
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# On a server, keep these outside the code folder (e.g. /etc/signbridge/)
# and point to them with FIREBASE_CONFIG_PATH / FIREBASE_ADMIN_PATH.
FIREBASE_CONFIG_PATH = Path(os.environ.get("FIREBASE_CONFIG_PATH") or PROJECT_ROOT / "firebase.json")
FIREBASE_ADMIN_PATH = Path(os.environ.get("FIREBASE_ADMIN_PATH") or PROJECT_ROOT / "firebase-admin.json")


with FIREBASE_CONFIG_PATH.open(encoding="utf-8") as f:
    _firebase_config = json.load(f)

_database_url = _firebase_config["databaseURL"]


try:
    firebase_admin.get_app()
except ValueError:
    firebase_admin.initialize_app(
        credentials.Certificate(str(FIREBASE_ADMIN_PATH)),
        {
            "databaseURL": _database_url,
        },
    )