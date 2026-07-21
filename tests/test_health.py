"""Confirms the app can reach Postgres - this is what proves the sidecar works."""


def test_health_reports_db_reachable(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    assert body["database"] == "reachable"
