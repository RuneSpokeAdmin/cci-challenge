# Reference CI/CD Pipeline — Dockerized Flask API on CircleCI

A reference pipeline that builds a custom Docker image, tests it against a live
Postgres sidecar, collects results in CircleCI, and publishes the image to
Amazon ECR using OIDC — with **zero static cloud credentials** anywhere.

- **Build link:** _<paste passing CCI build URL here>_
- **Repo:** _<paste public GitHub URL here>_

## What it is

A small Flask + SQLAlchemy "widgets" REST API backed by Postgres. The
application is deliberately modest so the focus stays on the pipeline — but the
tests hit a real database, and the built image is smoke-tested as a running
container before it is ever published.

## Pipeline at a glance

```
 commit ─► [ test ] ──(pass, main only)──► [ build-and-publish ]
             │                                  │
             ├ pytest vs Postgres sidecar        ├ multi-stage docker build (DLC)
             ├ JUnit XML → CircleCI              ├ smoke-test running image
             └ coverage artifact                 ├ OIDC → short-lived AWS creds
                                                 └ push image to Amazon ECR
```

## How the challenge criteria map to this repo

| Requirement | Where it lives |
|---|---|
| Public VCS repo connected to CircleCI | this GitHub repo |
| Custom Docker image built in the pipeline | `Dockerfile` (multi-stage), built in `build-and-publish` |
| Testing with results collected by CircleCI | `pytest` → `test-results/junit.xml` → `store_test_results` |
| Uses a database | Postgres, exercised by every test |
| Sidecar / secondary container | `cimg/postgres:16.4` service container in the `python-with-db` executor |
| Off-the-shelf DB image | `cimg/postgres:16.4` |
| Conditional work to limit unnecessary work | publish job gated on `test` + `branches: only: main` |
| Shell + non-scripting language | Bash (`scripts/*.sh`) + Python (app under test) |
| Publish an artifact to PaaS/FaaS/IaaS | Docker image pushed to Amazon ECR |
| Only on merge to default branch | workflow `filters.branches.only: main` |
| Credentials not accessible outside approved builds | restricted `aws-oidc` context, used only by the main-only publish job |
| OIDC | CircleCI OIDC → AWS IAM role assumption; no static keys |

## Run it locally

```bash
docker compose up --build      # app on :8000, Postgres on :5432
curl localhost:8000/health
curl -X POST localhost:8000/widgets -H 'content-type: application/json' \
  -d '{"name":"sprocket","quantity":5}'
```

Or run the tests directly against a local Postgres:

```bash
pip install -r requirements-dev.txt
export DATABASE_URL=postgresql://postgres:postgres@localhost:5432/widgets
pytest
```

## Make the pipeline green

See **[SETUP.md](./SETUP.md)** for the AWS OIDC + ECR wiring (about 20 minutes).

## The full writeup

See **[WRITEUP.md](./WRITEUP.md)** for the architecture, design decisions,
CircleCI-specific optimizations, and trade-offs.
