# Deployment Guide

This guide walks through deploying the two CloudFormation stacks that make up the solution, using the `custom_kb_deployment_setup.sh` helper script.

For a description of what actually gets deployed, see [architecture.md](./architecture.md). For details of every resource in each stack, see [infrastructure.md](./infrastructure.md).

## Prerequisites

### Tooling on your workstation

- `bash` or `sh` (script targets POSIX sh with a `#!/bin/sh` shebang)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `grep`, `cut`, `sed`, `tr`, `rev` (all standard on macOS and Linux)

### AWS account setup

1. **Credentials.** Either export `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (and optional `AWS_SESSION_TOKEN`), or configure a named profile in `~/.aws/credentials`. The script accepts a `--profile` flag if you use profiles.
2. **Region.** Pick a region that supports **Bedrock**, **Bedrock Knowledge Bases**, **OpenSearch Serverless**, and **Textract async document analysis**. The script defaults to `us-east-1`.
3. **Bedrock model access.** In the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess), request access to:
   - `amazon.titan-embed-text-v1` (used by the Knowledge Base for embeddings)
   - `amazon.nova-micro-v1:0` (used by `KBParserLambda` to reformat parsed documents)
4. **IAM permissions.** The identity running the script needs to be able to create IAM roles, S3 buckets, Lambda functions, OpenSearch Serverless collections + policies + indexes, and Bedrock Knowledge Bases + data sources. In practice this is close to admin-level and is best done from a dedicated deployment role.

### Service quotas to check

- OpenSearch Serverless collections in the region (default limit is low; you need at least 1 free `VECTORSEARCH` slot).
- Concurrent Textract async document analysis jobs (relevant when bulk-loading).

## The deployment script

The helper script lives at `custom-knowldegebase/custom_kb_deployment_setup.sh`. It deploys **two stacks in order**, then runs a set of post-deployment checks.

### Options

| Flag | Default | Purpose |
|---|---|---|
| `-r`, `--region` | `us-east-1` (or profile region) | AWS region to deploy into. |
| `-s`, `--stack1-name` | `custom-kb-aoss` | Name for the AOSS + IAM stack. |
| `-k`, `--stack2-name` | `custom-kb-app` | Name for the KB + Lambdas + S3 stack. |
| `-p`, `--profile` | `default` | AWS CLI profile to use. |
| `--stack1-only` | — | Deploy only Stack 1. |
| `--stack2-only` | — | Deploy only Stack 2 (Stack 1 must already exist and export the four values Stack 2 imports). |
| `--test-only` | — | Skip deployment and only run the post-deployment tests. |
| `-h`, `--help` | — | Print usage. |

### Typical invocations

```bash
# Change into the solution directory (the script expects to find ./resources/*.yaml)
cd custom-knowldegebase

# Simplest case: default region, default profile, default stack names
bash custom_kb_deployment_setup.sh

# Named profile, different region
bash custom_kb_deployment_setup.sh --profile my-sandbox --region us-west-2

# Custom stack names (useful if you want two isolated deployments in the same account)
bash custom_kb_deployment_setup.sh --stack1-name demo-aoss --stack2-name demo-kb

# Deploy only Stack 1 (useful while iterating on Stack 1 IAM or AOSS policies)
bash custom_kb_deployment_setup.sh --stack1-only

# Re-run post-deploy tests without redeploying
bash custom_kb_deployment_setup.sh --test-only
```

## What the script does, step by step

1. **Parse arguments** and set defaults.
2. **Resolve credentials.** If `AWS_ACCESS_KEY_ID` isn't already exported, it reads `~/.aws/credentials` for the requested profile.
3. **Resolve region.** Uses `--region`, else the region field for the profile in `~/.aws/config`, else falls back to `us-east-1`.
4. **Verify connectivity** with `aws s3 ls` and `aws sts get-caller-identity`.
5. **Verify templates** are present at `./resources/stack-1-aoss.yaml` and `./resources/stack-2-kb.yaml`.
6. **Deploy Stack 1** (`stack-1-aoss.yaml`) with `aws cloudformation deploy` and `CAPABILITY_IAM CAPABILITY_NAMED_IAM`.
7. **Deploy Stack 2** (`stack-2-kb.yaml`) with the same capabilities and `--parameter-overrides AossStackName=<stack1-name>` so Stack 2 can `Fn::ImportValue` from Stack 1.
8. **Run post-deployment tests** (see below).
9. **Print outputs** for both stacks as a table.
10. **Print a test summary** and exit non-zero if any test failed.

## Post-deployment tests

The script runs seven automated checks:

| # | Check | What it validates |
|---|---|---|
| 1 | `Stack 1 status` ends in `COMPLETE` | Stack 1 finished cleanly (`CREATE_COMPLETE` or `UPDATE_COMPLETE`). |
| 2 | `Stack 2 status` ends in `COMPLETE` | Stack 2 finished cleanly. |
| 3 | Exports `<stack1>-CollectionArn`, `<stack1>-CollectionEndpoint`, `<stack1>-LambdaRoleArn`, `<stack1>-BedrockKBRoleArn` are non-empty. | Stack 1 has published everything Stack 2 imports. |
| 4 | AOSS collection is `ACTIVE`. | The vector search collection is ready to serve traffic. |
| 5 | Bedrock KB is `ACTIVE`. | The Knowledge Base finished provisioning and can accept ingestion jobs. |
| 6 | Documents S3 bucket exists (`s3api head-bucket` returns 200). | The bucket that Lambdas and the KB use is reachable. |
| 7 | Both Lambdas (`document-parser`, `kb-parser`) report `State: Active`. | The Lambda service has finished packaging both functions and they are ready to run. |

If any test fails, the script prints `[FAIL] ...` for that check and exits with an error at the end. Full stack outputs are still printed so you can inspect what did or didn't get created.

## Post-deployment: use the Knowledge Base

Deployment does not automatically upload documents or trigger the first ingestion. See [usage.md](./usage.md) for how to upload sample PDFs, sync the data source, and query the Knowledge Base.

## Teardown

Because Stack 2 imports from Stack 1, delete in reverse order:

```bash
# 1. Empty the two S3 buckets first (CloudFormation cannot delete non-empty buckets)
DOC_BUCKET=$(aws cloudformation describe-stacks --stack-name custom-kb-app \
    --query "Stacks[0].Outputs[?OutputKey=='DocumentBucketName'].OutputValue" --output text)
aws s3 rm "s3://$DOC_BUCKET" --recursive
aws s3 rb "s3://$DOC_BUCKET"

# Then do the same for the access-logs-* bucket (name is not exported but follows the same pattern)

# 2. Delete Stack 2, then Stack 1
aws cloudformation delete-stack --stack-name custom-kb-app
aws cloudformation wait stack-delete-complete --stack-name custom-kb-app
aws cloudformation delete-stack --stack-name custom-kb-aoss
aws cloudformation wait stack-delete-complete --stack-name custom-kb-aoss
```

> **Note:** The Bedrock data source uses `DataDeletionPolicy: RETAIN`. Deleting the Knowledge Base will not delete the underlying source documents or the vectors already written to OpenSearch Serverless. Deleting the AOSS collection (part of Stack 1) will drop the vectors.

## Troubleshooting

**Stack 2 fails with an "index does not exist" or "endpoint not reachable" error.**
Stack 1 probably has not finished. Wait until the AOSS collection status is `ACTIVE` before deploying Stack 2 (use `--stack1-only` first, then `--stack2-only` once the collection is ready).

**`AccessDeniedException` when invoking Bedrock from `KBParserLambda`.**
Model access for `amazon.nova-micro-v1:0` has not been granted in the region. Open the Bedrock console **Model access** page and request access, then re-invoke the Lambda (or re-upload the parsed JSON to `parsed_files/`).

**KB ingestion job fails with `titan-embed-text-v1` access denied.**
Same cause, different model. Grant access to `amazon.titan-embed-text-v1`.

**Textract job stays in `IN_PROGRESS` forever.**
The Lambda has a 300 second timeout. Very large scanned PDFs may exceed this. Split the document, or increase the timeout in `stack-2-kb.yaml` (`Timeout: 300`) and redeploy.
