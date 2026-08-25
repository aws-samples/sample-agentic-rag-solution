# Architecture

This document describes the architecture of the **Sample Agentic RAG Solution** — a customization layer for Amazon Bedrock Knowledge Bases that improves ingestion quality for a wider variety of document types (including scanned PDFs and handwritten images) before they are embedded and indexed for retrieval.

## Overview

The solution implements a serverless, event-driven document ingestion pipeline that sits **in front of** a Bedrock Knowledge Base. Instead of pointing the Knowledge Base directly at raw customer documents, it first extracts text with Amazon Textract, then normalizes and re-formats the extracted content with a Bedrock foundation model. Only the cleaned, model-formatted output is fed to the Knowledge Base for embedding and vector indexing.

This "pre-processing" step is what makes the RAG pipeline **agentic**: an LLM (Amazon Nova Micro) actively re-writes each parsed document into a consistent, retrieval-friendly form rather than passing raw OCR text through.

## High-level architecture

```
                         ┌────────────────────────┐
                         │   User / Application   │
                         └───────────┬────────────┘
                                     │  1. Upload
                                     ▼
                    ┌──────────────────────────────────────┐
                    │  S3: documents-<stack>-<acct>        │
                    │                                      │
                    │   raw_files/*.pdf, *.png             │
                    │   parsed_files/*.json                │
                    │   parsed_kb_documents/*.txt          │
                    └───────────┬─────────────┬────────────┘
                                │             │
                     2. Event   │             │  4. Event
                                ▼             ▼
                    ┌────────────────┐   ┌────────────────┐
                    │ DocumentParser │   │  KBParser      │
                    │  (Lambda)      │   │  (Lambda)      │
                    └────────┬───────┘   └────────┬───────┘
                             │                    │
                     3. OCR  │                    │  5. Format
                             ▼                    ▼
                    ┌────────────────┐   ┌────────────────┐
                    │  Amazon        │   │  Bedrock:      │
                    │  Textract      │   │  Nova Micro    │
                    └────────────────┘   └────────────────┘

                                            6. Sync (manual or scheduled)
                                                       │
                                                       ▼
                                          ┌─────────────────────────┐
                                          │  Bedrock Knowledge Base │
                                          │  (Titan Embed v1)       │
                                          └───────────┬─────────────┘
                                                      │  7. Embed + index
                                                      ▼
                                          ┌─────────────────────────┐
                                          │  OpenSearch Serverless  │
                                          │  Vector Collection      │
                                          │  (index: document_index)│
                                          └─────────────────────────┘
```

## Components

### Storage layer

| Resource | Purpose |
|---|---|
| `DocumentBucket` (S3) | Single bucket that holds three logical stages of a document, separated by key prefix (`raw_files/`, `parsed_files/`, `parsed_kb_documents/`). Versioned, KMS-encrypted, public access blocked, access-logged. |
| `AccessLogsBucket` (S3) | Server access log target for `DocumentBucket`. Also self-logs. |
| `DocumentCollection` (AOSS) | OpenSearch Serverless `VECTORSEARCH` collection that stores the KB's vector index. |
| `VectorIndex` | The `document_index` inside the AOSS collection. HNSW graph on FAISS, `l2` space, 1536 dimensions to match the Titan embedding model. |

### Compute layer

| Resource | Runtime | Trigger | Role |
|---|---|---|---|
| `DocumentParserLambda` | Python 3.14 | S3 `ObjectCreated` on `raw_files/*.pdf` and `raw_files/*.png` | Starts a Textract `StartDocumentAnalysis` job (`LAYOUT`, `TABLES`, `FORMS`), polls until `SUCCEEDED`, concatenates every `LINE` block, writes the result to `parsed_files/<name>_parsed.json`. |
| `KBParserLambda` | Python 3.14 | S3 `ObjectCreated` on `parsed_files/*.json` | Reads the parsed JSON, sends it to Bedrock **Amazon Nova Micro** via `converse()` with a prompt that asks the model to format the content into a structured, error-free document tagged with the file name, then writes the model output to `parsed_kb_documents/<name>.txt`. |

Both Lambdas share a single execution role from Stack 1 (see IAM below) and have a 300 second timeout and 1024 MB memory.

### Retrieval layer

| Resource | Purpose |
|---|---|
| `DocumentKnowledgeBase` (Bedrock) | Bedrock Knowledge Base of type `VECTOR` backed by AOSS. Uses **Amazon Titan Text Embeddings v1** (`amazon.titan-embed-text-v1`, 1536-dim). |
| `DocumentDataSource` (Bedrock) | S3 data source scoped to the `parsed_kb_documents/` prefix on `DocumentBucket`. `DataDeletionPolicy: RETAIN`. |

### IAM

| Role | Trusts | Grants (highlights) |
|---|---|---|
| `LambdaExecutionRole` | `lambda.amazonaws.com` | `AWSLambdaBasicExecutionRole` managed policy, `s3:GetObject`/`PutObject` on `documents-*-<acct>/*`, `aoss:APIAccessAll` on collections in the account, `bedrock:InvokeModel` on `amazon.nova-micro-v1:0`, `textract:StartDocumentAnalysis`/`GetDocumentAnalysis` (Textract does not support resource-level ARNs, so `*` is required). |
| `BedrockKBRole` | `bedrock.amazonaws.com` (with `aws:SourceAccount` and `aws:SourceArn` conditions scoped to the account and to `knowledge-base/*`) | `bedrock:InvokeModel` on `amazon.titan-embed-text-v1`, `s3:GetObject`/`ListBucket` on documents bucket, `aoss:APIAccessAll` on collections in the account. |

## Data flow

The pipeline is fully event-driven — no orchestration service (Step Functions, EventBridge rules, etc.) is required.

1. **Upload.** A client (console, SDK, or CLI) puts a PDF or PNG under the `raw_files/` prefix of `DocumentBucket`.
2. **Parse.** The S3 event notification invokes `DocumentParserLambda`. It calls `Textract.start_document_analysis`, polls `get_document_analysis` every 5 seconds until the job finishes, walks every result page, keeps every `LINE` block, and writes `parsed_files/<name>_parsed.json`.
3. **Format.** The new `parsed_files/*.json` object triggers `KBParserLambda`. It reads the JSON, sends it to Bedrock Nova Micro via the `converse` API (`maxTokens=6000`, `temperature=0.5`, `topP=0.9`), and writes the model's text output to `parsed_kb_documents/<name>.txt`.
4. **Ingest.** The Bedrock Knowledge Base data source is configured against `parsed_kb_documents/`. Starting an ingestion job (from the console, CLI, or SDK) makes Bedrock read the `.txt` files, chunk them, embed each chunk with Titan v1, and upsert them into the `document_index` on OpenSearch Serverless.
5. **Query.** Downstream applications call `bedrock-agent-runtime` (`Retrieve` or `RetrieveAndGenerate`) against the Knowledge Base ID. Bedrock embeds the query, searches AOSS, and returns the top-K matches.

## Why this design

- **Textract before embedding.** OCR-quality varies wildly across scanned PDFs and images. Running Textract with `LAYOUT | TABLES | FORMS` and taking the `LINE` blocks gives a stable text stream that survives most rendering artifacts.
- **LLM re-formatting before embedding.** Nova Micro rewrites the OCR output into a structured document. This reduces noise (headers/footers, broken lines, hyphenation) before the text is chunked and embedded, which typically improves retrieval quality.
- **Prefix-based staging in one bucket.** Keeping `raw_files/`, `parsed_files/`, and `parsed_kb_documents/` in the same bucket lets the two Lambdas share a single set of S3 permissions and a single set of event notifications, and makes the KB data source configuration trivial (`InclusionPrefixes: ['parsed_kb_documents/']`).
- **Two CloudFormation stacks.** The AOSS collection must be `ACTIVE` before the `AWS::OpenSearchServerless::Index` resource in Stack 2 can call the collection endpoint. Splitting the deployment lets Stack 1 finish (and export its outputs via `Fn::ImportValue`) before Stack 2's early-validation step runs.

## Regions and models

- Default region: `us-east-1` (the deployment script defaults to this).
- Embedding model: `amazon.titan-embed-text-v1` (1536-dim). Must be enabled in the target region under Bedrock **Model access**.
- Generation model (used only by `KBParserLambda`): `amazon.nova-micro-v1:0`. Must also be enabled in the target region.
- Amazon Textract asynchronous document analysis must be available in the target region.

## Known caveats

- The Stack 1 AOSS **data access policy** lists a hardcoded principal (`arn:aws:sts::<account>:assumed-role/Admin/abhagam-Isengard`) in addition to the Lambda and Bedrock KB roles. This principal was included to give the original developer direct index access from their console session. It does not block deployment in a different account, but you may want to remove or replace it with your own admin principal before deploying to a shared account.
- Both Lambdas embed their handler code inline as `ZipFile` for portability. This keeps the templates self-contained but makes the code harder to unit-test than a packaged Lambda would be.
- The Bedrock Knowledge Base **data source is not synced automatically** when new `parsed_kb_documents/*.txt` objects appear. You must trigger an ingestion job (see [usage.md](./usage.md)) each time you want new documents indexed.
