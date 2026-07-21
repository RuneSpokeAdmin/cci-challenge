"""Application factory for the widgets API.

A deliberately small but real Flask + SQLAlchemy service. It exists to give the
pipeline something genuine to test against a live Postgres container rather than
a mocked stand-in - the health check and the CRUD routes both hit the database.
"""
from __future__ import annotations

import os

from flask import Flask, jsonify, request
from sqlalchemy import text

from .db import db
from .models import Widget


def create_app(config: dict | None = None) -> Flask:
    app = Flask(__name__)

    # DATABASE_URL is supplied by the environment. In CI it points at the
    # Postgres service container; locally it points at docker-compose.
    app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
        "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/widgets"
    )
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    if config:
        app.config.update(config)

    db.init_app(app)

    with app.app_context():
        db.create_all()

    @app.get("/health")
    def health():
        """Liveness + DB readiness. Used by the pipeline to confirm the
        sidecar is reachable before tests run."""
        try:
            db.session.execute(text("SELECT 1"))
            return jsonify(status="ok", database="reachable"), 200
        except Exception as exc:  # pragma: no cover - defensive
            return jsonify(status="degraded", database=str(exc)), 503

    @app.get("/widgets")
    def list_widgets():
        widgets = Widget.query.order_by(Widget.id).all()
        return jsonify([w.to_dict() for w in widgets]), 200

    @app.post("/widgets")
    def create_widget():
        payload = request.get_json(silent=True) or {}
        name = payload.get("name")
        if not name or not isinstance(name, str):
            return jsonify(error="'name' is required and must be a string"), 400
        widget = Widget(name=name, quantity=int(payload.get("quantity", 0)))
        db.session.add(widget)
        db.session.commit()
        return jsonify(widget.to_dict()), 201

    @app.get("/widgets/<int:widget_id>")
    def get_widget(widget_id: int):
        widget = db.session.get(Widget, widget_id)
        if widget is None:
            return jsonify(error="not found"), 404
        return jsonify(widget.to_dict()), 200

    return app
