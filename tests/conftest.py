"""Pytest fixtures. The app is wired to the live Postgres service container in
CI (via DATABASE_URL), so these tests exercise the real database - not a mock."""
import pytest

from app import create_app
from app.db import db as _db


@pytest.fixture()
def app():
    app = create_app({"TESTING": True})
    with app.app_context():
        _db.create_all()
        yield app
        _db.session.remove()
        _db.drop_all()


@pytest.fixture()
def client(app):
    return app.test_client()
