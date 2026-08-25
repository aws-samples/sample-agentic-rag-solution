# Usage Guide

This guide covers what to do **after** [deployment](./deployment.md) is complete: uploading documents, triggering ingestion, and querying the Knowledge Base.

## Prerequisites

- Both stacks (`custom-kb-aoss` and `custom-kb-app` by default) deployed and healthy.
- The deployment script's post-deploy tests all show `[PASS]`.
- `amazon.titan-embed-text-v1` and `amazon.nova-micro-v1:0` model access granted in the target region.

Collect these three values from the Stack 2 outputs — you'll use them below.

```bash
STACK2=custom-kb-app
REGION=us-east-1

BUCKET=$(aws cloudformation describe-stacks --stack-name $STACK2 --region $REGION \
    --query "Stacks[0].Outputs[?OutputKey=='DocumentBucketName'].OutputValue" --output text)
KB_ID=$(aws cloudformation describe-stacks --stack-name $STACK2 --region $REGION \
    --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" --output text)

# Find the data source ID (only one exists per KB in this template)
DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --region $REGION \
    --query "dataSourceSummaries[0].dataSourceId" --output text)

echo "Bucket:      $BUCKET"
echo "KB ID:       $KB_ID"
echo "DataSource:  $DS_ID"
```

## Sample documents

The repository ships a few sample documents you can use to smoke-test the pipeline:

| File | Type | Contents |
|---|---|---|
| `custom-knowldegebase/usecase/P_1-Sample.1.pdf` | PDF | Sample structured document. |
| `custom-knowldegebase/usecase/employee_enrollment.pdf` | PDF | Enrollment form (has tables + form fields). |
| `custom-knowldegebase/usecase/service_providers.pdf` | PDF | Free-text document. |
| `custom-knowldegebase/usecase/handwritten.pdf` | PDF | Scanned handwritten notes. |
| `custom-knowldegebase/usecase/test_handwritten_document.png` | PNG | Scanned handwritten image (matches the `.png` event rule). |

## End-to-end flow

### 1. Upload a document to `raw_files/`

Uploading is what starts the whole pipeline. Only files under `raw_files/` with a `.pdf` or `.png` suffix will trigger the parser.

```bash
aws s3 cp custom-knowldegebase/usecase/employee_enrollment.pdf \
    s3://$BUCKET/raw_files/employee_enrollment.pdf
```

To bulk-load the samples:

```bash
aws s3 cp custom-knowldegebase/usecase/ s3://$BUCKET/raw_files/ \
    --recursive --exclude "*" --include "*.pdf" --include "*.png"
```

### 2. Wait for Textract → parsed JSON

`DocumentParserLambda` fires on the S3 event, starts a Textract async job, and waits for it to finish (typically 10–60 seconds for small documents). When it finishes, a JSON file appears under `parsed_files/`.

```bash
# List what has been parsed so far
aws s3 ls s3://$BUCKET/parsed_files/

# Inspect one of them
aws s3 cp s3://$BUCKET/parsed_files/employee_enrollment_parsed.json - | head -c 2000
```

The JSON payload is `{"document": "<key>", "extracted_text": ["<line1>", "<line2>", ...]}` — one entry per `LINE` block Textract emitted.

### 3. Wait for Nova Micro → KB-ready text

The moment the JSON lands in `parsed_files/`, `KBParserLambda` fires. It sends the JSON to Amazon Nova Micro and writes the reformatted output under `parsed_kb_documents/`.

```bash
aws s3 ls s3://$BUCKET/parsed_kb_documents/
aws s3 cp s3://$BUCKET/parsed_kb_documents/employee_enrollment.txt - | head -c 2000
```

If the file doesn't appear:

```bash
# Check the KBParser Lambda logs
FN=$(aws cloudformation describe-stacks --stack-name $STACK2 --region $REGION \
    --query "Stacks[0].Outputs[?OutputKey=='KBParserLambdaArn'].OutputValue" --output text \
    | rev | cut -d: -f1 | rev)
aws logs tail /aws/lambda/$FN --since 15m --region $REGION
```

The most common failure is `AccessDeniedException` on `bedrock:InvokeModel` — model access for Nova Micro has not been granted in the region.

### 4. Trigger a Bedrock ingestion job

The Bedrock Knowledge Base **does not automatically ingest** new `.txt` files. You have to start an ingestion job.

```bash
JOB_ID=$(aws bedrock-agent start-ingestion-job \
    --knowledge-base-id $KB_ID \
    --data-source-id $DS_ID \
    --region $REGION \
    --query "ingestionJob.ingestionJobId" --output text)

echo "Started ingestion job: $JOB_ID"
```

Poll for completion:

```bash
while true; do
  STATUS=$(aws bedrock-agent get-ingestion-job \
      --knowledge-base-id $KB_ID --data-source-id $DS_ID --ingestion-job-id $JOB_ID \
      --region $REGION --query "ingestionJob.status" --output text)
  echo "$(date +%H:%M:%S) status=$STATUS"
  [ "$STATUS" = "COMPLETE" ] || [ "$STATUS" = "FAILED" ] && break
  sleep 10
done

# Statistics for the completed job
aws bedrock-agent get-ingestion-job \
    --knowledge-base-id $KB_ID --data-source-id $DS_ID --ingestion-job-id $JOB_ID \
    --region $REGION --query "ingestionJob.statistics"
```

You should see `numberOfDocumentsScanned`, `numberOfNewDocumentsIndexed`, and (on re-runs) `numberOfModifiedDocumentsIndexed`.

### 5. Query the Knowledge Base

Two endpoints are available on the `bedrock-agent-runtime` service. Both live under the same KB ID.

**Retrieve raw chunks:**

```bash
aws bedrock-agent-runtime retrieve \
    --knowledge-base-id $KB_ID \
    --retrieval-query "text=What benefits are offered during employee enrollment?" \
    --region $REGION
```

**Retrieve and generate a natural-language answer:**

```bash
aws bedrock-agent-runtime retrieve-and-generate \
    --input "text=Summarize the employee enrollment process" \
    --retrieve-and-generate-configuration '{
      "type": "KNOWLEDGE_BASE",
      "knowledgeBaseConfiguration": {
        "knowledgeBaseId": "'"$KB_ID"'",
        "modelArn": "arn:aws:bedrock:'"$REGION"'::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
      }
    }' \
    --region $REGION
```

> The `modelArn` for `retrieve-and-generate` is any generation-capable Bedrock model you have access to — this example uses Claude 3 Haiku, but Claude Sonnet or Nova Pro work too. It is **not** the model used to build the KB.

## Adding your own documents

Anything you drop into `s3://$BUCKET/raw_files/` with a `.pdf` or `.png` suffix flows through the same pipeline. To wire up more file types:

1. Add a new `LambdaConfigurations` entry to `DocumentBucket` in `stack-2-kb.yaml` (e.g. `.tiff`, `.jpg`).
2. Redeploy Stack 2.
3. Confirm the mime type is one Textract supports.

## Re-running after code changes

If you edit either Lambda's inline code in `stack-2-kb.yaml`:

```bash
cd custom-knowldegebase
bash custom_kb_deployment_setup.sh --stack2-only
```

If you edit the vector index mapping or KB configuration, expect a replacement of the KB. In that case, back up (or export) any critical data first, since the AOSS index will be dropped when the vector index is recreated.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Uploaded to `raw_files/`, nothing in `parsed_files/`. | Suffix isn't `.pdf` or `.png`, or key isn't under `raw_files/`. | Rename the object or upload to the right prefix. |
| `parsed_files/` fills up but `parsed_kb_documents/` stays empty. | Nova Micro access not granted, or `KBParserLambda` timed out. | Check the Lambda's CloudWatch log group; grant model access; retry by re-uploading the parsed JSON. |
| Ingestion job status `FAILED`. | KB role can't read the bucket, or Titan Embed v1 access not granted. | Look at `ingestionJob.failureReasons`; grant embedding model access; confirm the bucket policy hasn't been altered. |
| `Retrieve` returns 0 results. | No ingestion job has been run since the last upload, or your query is not in the corpus. | Start an ingestion job (step 4) or check `numberOfNewDocumentsIndexed` on the last job. |
| Textract job stays `IN_PROGRESS` past 5 minutes. | Very large scanned PDF is exceeding the Lambda's 300 s timeout. | Split the PDF, or raise `Timeout` on `DocumentParserLambda` in Stack 2 and redeploy. |
