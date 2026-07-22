# Reference CI/CD Pipeline — Dockerized Flask API on CircleCI

A reference pipeline that builds a custom Docker image, tests it against a live
Postgres sidecar, collects the results in CircleCI, and publishes the image to
Amazon ECR using OIDC — with no static cloud credentials stored anywhere.

- **Repo:** https://github.com/RuneSpokeAdmin/cci-challenge
- **Passing build:** https://app.circleci.com/pipelines/circleci/WdMV6fYgJiD46iDHM48FP4/34d8b38f-8f84-4ac5-9f7d-5f9d0f0f6089/6/details?useNewPipelines=true&workflowId=b6af7020-7693-41d7-8b07-eab729f459ca

## What it is

A small Flask + SQLAlchemy "widgets" REST API backed by Postgres. The app is
deliberately simple as the focus is the pipeline — but the tests hit a real
database, and the built image gets run and health-checked as a live container
before it's ever published.

## The pipeline process

```
 commit -> [ test ] --(pass, main only)--> [ build-and-publish ]
             |                                  |
             |- pytest vs Postgres sidecar       |- multi-stage docker build (DLC)
             |- JUnit XML -> CircleCI            |- smoke-test the running image
             |- coverage artifact               |- OIDC -> short-lived AWS creds
                                                |- push image to Amazon ECR
```

## How each challenge requirement is met

| Requirement | Where it lives |
|---|---|
| Public VCS repo connected to CircleCI | this GitHub repo |
| Custom Docker image built in the pipeline | `Dockerfile` (multi-stage), built in `build-and-publish` |
| Testing with results collected by CircleCI | `pytest` -> `test-results/junit.xml` -> `store_test_results` |
| Uses a database | Postgres, hit by every test |
| Sidecar / secondary container | `cimg/postgres:16.4` service container in the `python-with-db` executor |
| Off-the-shelf DB image | `cimg/postgres:16.4` |
| Conditional work to limit unnecessary work | publish job gated on `test` passing + `branches: only: main` |
| Shell + non-scripting language | Bash (`scripts/*.sh`) + Python (the app) |
| Publish an artifact to PaaS/FaaS/IaaS | Docker image pushed to Amazon ECR |
| Only on merge to default branch | workflow `filters.branches.only: main` |
| Credentials not accessible outside approved builds | restricted `aws-oidc` context, only the main-only publish job can read it |
| OIDC | CircleCI OIDC -> AWS IAM role; no static keys |

## Run it locally

```bash
docker compose up --build      # app on :8000, Postgres on :5432
curl localhost:8000/health
curl -X POST localhost:8000/widgets -H 'content-type: application/json' \
  -d '{"name":"sprocket","quantity":5}'
```

Or just run the tests against a local Postgres:

```bash
pip install -r requirements-dev.txt
export DATABASE_URL=postgresql://postgres:postgres@localhost:5432/widgets
pytest
```

## Wiring up the pipeline

See **[SETUP.md](./SETUP.md)** for the AWS OIDC + ECR setup — about 20 minutes.

## The full writeup

See **[WRITEUP.md](./WRITEUP.md)** for the architecture, the design decisions,
the CircleCI features doing the work, and the trade-offs.
