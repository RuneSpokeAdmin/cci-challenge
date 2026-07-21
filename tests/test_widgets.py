"""CRUD tests against a real Postgres-backed model."""


def test_list_empty(client):
    resp = client.get("/widgets")
    assert resp.status_code == 200
    assert resp.get_json() == []


def test_create_and_fetch(client):
    resp = client.post("/widgets", json={"name": "sprocket", "quantity": 5})
    assert resp.status_code == 201
    created = resp.get_json()
    assert created["name"] == "sprocket"
    assert created["quantity"] == 5

    resp = client.get(f"/widgets/{created['id']}")
    assert resp.status_code == 200
    assert resp.get_json()["name"] == "sprocket"


def test_create_requires_name(client):
    resp = client.post("/widgets", json={"quantity": 3})
    assert resp.status_code == 400
    assert "name" in resp.get_json()["error"]


def test_missing_widget_returns_404(client):
    resp = client.get("/widgets/99999")
    assert resp.status_code == 404


def test_create_persists_across_requests(client):
    client.post("/widgets", json={"name": "gear", "quantity": 1})
    client.post("/widgets", json={"name": "cog", "quantity": 2})
    resp = client.get("/widgets")
    names = [w["name"] for w in resp.get_json()]
    assert "gear" in names and "cog" in names
