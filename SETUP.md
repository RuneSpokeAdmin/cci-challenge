# Setup Guide

Everything needed to take this repo from clone to a green CircleCI build that
publishes to Amazon ECR over OIDC. Budget ~20 minutes.

## 0. Prerequisites

- A public GitHub repo (fork/clone this into one)
- A CircleCI account connected to that repo
- An AWS account you control

---

## 1. Create the ECR repository

```bash
aws ecr create-repository --repository-name widgets-api --region us-east-1
```

Note the region you use; you will need it again.

---

## 2. Wire up OIDC between CircleCI and AWS

CircleCI issues every job a signed OIDC token. AWS is configured to trust that
token and hand back short-lived credentials. **No AWS access keys are ever
stored in CircleCI.**

### 2a. Get your CircleCI Organization ID

CircleCI → **Organization Settings → Overview → Organization ID**. Copy it.

### 2b. Create the OIDC identity provider in AWS

- Provider URL: `https://oidc.circleci.com/org/<ORG_ID>`
- Audience: `<ORG_ID>`

```bash
ORG_ID=<your-org-id>
aws iam create-open-id-connect-provider \
  --url "https://oidc.circleci.com/org/${ORG_ID}" \
  --client-id-list "${ORG_ID}" \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
```

### 2c. Create an IAM role the job can assume

Trust policy (`trust.json`) — this is what enforces *only approved builds*:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.circleci.com/org/<ORG_ID>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.circleci.com/org/<ORG_ID>:aud": "<ORG_ID>"
      }
    }
  }]
}
```

```bash
aws iam create-role \
  --role-name circleci-ecr-publisher \
  --assume-role-policy-document file://trust.json

aws iam put-role-policy \
  --role-name circleci-ecr-publisher \
  --policy-name ecr-push \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "*"
    }]
  }'
```

Copy the role ARN it prints.

---

## 3. Create the restricted CircleCI context

CircleCI → **Organization Settings → Contexts → Create Context** → name it
`aws-oidc`. Add these environment variables:

| Variable | Value |
|---|---|
| `AWS_OIDC_ROLE_ARN` | the role ARN from step 2c |
| `AWS_REGION` | e.g. `us-east-1` |
| `ECR_REPO_NAME` | `widgets-api` |

> The context is what limits credentials to approved builds. Because the
> `build-and-publish` job only runs on `main`, and only that job uses the
> context, PRs and feature branches can never reach these values.

*(Optional but recommended: restrict the context to a security group so only
approved users/branches can consume it.)*

---

## 4. Push and watch it go green

```bash
git push origin main
```

- On a **PR / feature branch**: only the `test` job runs. No publish, no creds.
- On **`main`**: `test` runs, then `build-and-publish` builds the image,
  smoke-tests it, assumes the role via OIDC, and pushes to ECR.

Confirm the image landed:

```bash
aws ecr list-images --repository-name widgets-api --region us-east-1
```
