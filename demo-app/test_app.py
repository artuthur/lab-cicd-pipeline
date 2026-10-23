from app import app


def test_health_returns_ok_and_a_version():
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    data = response.get_json()
    assert data["status"] == "ok"
    assert data["version"]


def test_index_mentions_the_version():
    client = app.test_client()
    response = client.get("/")
    assert response.status_code == 200
    assert b"demo-app version" in response.data
