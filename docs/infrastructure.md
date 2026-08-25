# Infrastructure Reference

This is a detailed reference for every resource in the two CloudFormation templates that make up the solution. Use it alongside [architecture.md](./architecture.md) (system view) and [deployment.md](./deployment.md) (how to deploy).

Templates:

- `custom-knowldegebase/resources/stack-1-aoss.yaml`
- `custom-knowldegebase/resources/stack-2-kb.yaml`

## Naming convention

Every resource uses the pattern:

```
${AWS::StackName}-${StackUUID}-<suffix>
```

where `StackUUID` is the first 8 hex characters of the CloudFormation stack ID (extracted with nested `Fn::Split`/`Fn::Select`). This produces short, deterministic names that stay stable across updates of the same stack but change if the stack is deleted and recreated.

---

## Stack 1 — `stack-1-aoss.yaml`

**Purpose.** Provision the OpenSearch Serverless vector collection and the IAM roles that Stack 2 will need. Must finish before Stack 2 is deployed so the collection endpoint is reachable when Stack 2's `AWS::OpenSearchServerless::Index` calls it during early validation.

**Parameters.** None.

### Resources

#### `LambdaExecutionRole` — `AWS::IAM::Role`

- **Trust policy.** `lambda.amazonaws.com` via `sts:AssumeRole`.
- **Managed policy.** `AWSLambdaBasicExecutionRole` (CloudWatch Logs).
- **Inline policy `LambdaS3AossBedrockPolicy`.**

  | Actions | Resources |
  |---|---|
  | `s3:ListBucket` | `arn:aws:s3:::documents-*-<account>` |
  | `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::documents-*-<account>/*` |
  | `aoss:APIAccessAll` | `arn:aws:aoss:<region>:<account>:collection/*` |
  | `bedrock:InvokeModel` | `arn:aws:bedrock:<region>::foundation-model/amazon.nova-micro-v1:0` |
  | `textract:StartDocumentAnalysis`, `textract:GetDocumentAnalysis` | `*` (Textract does not support resource-level ARNs) |

- **Used by.** Both `DocumentParserLambda` and `KBParserLambda` in Stack 2 (imported via `${AossStackName}-LambdaRoleArn`).

#### `BedrockKBRole` — `AWS::IAM::Role`

- **Trust policy.** `bedrock.amazonaws.com` via `sts:AssumeRole`, guarded by:
  - `aws:SourceAccount == <account>`
  - `aws:SourceArn` like `arn:aws:bedrock:<region>:<account>:knowledge-base/*`

  These conditions block the confused-deputy pattern where a different account's Bedrock service could assume this role.

- **Inline policies.**

  | Policy | Actions | Resources |
  |---|---|---|
  | `BedrockEmbeddingModelAccess` | `bedrock:ListFoundationModels`, `bedrock:ListCustomModels` | `*` |
  | `BedrockEmbeddingModelAccess` | `bedrock:InvokeModel` | `arn:aws:bedrock:<region>::foundation-model/amazon.titan-embed-text-v1` |
  | `BedrockS3Access` | `s3:ListBucket` | `arn:aws:s3:::documents-*-<account>` |
  | `BedrockS3Access` | `s3:GetObject` | `arn:aws:s3:::documents-*-<account>/*` |
  | `BedrockAOSSAccess` | `aoss:APIAccessAll` | `arn:aws:aoss:<region>:<account>:collection/*` |

- **Used by.** `DocumentKnowledgeBase` in Stack 2 (imported via `${AossStackName}-BedrockKBRoleArn`).

#### `EncryptionPolicy` — `AWS::OpenSearchServerless::SecurityPolicy`

- Type: `encryption`. Uses the AWS-owned key (`AWSOwnedKey: true`).
- Scoped to `collection/${AWS::StackName}-*` so it applies to the collection created below.
- Required by AOSS **before** the collection resource can be created.

#### `NetworkPolicy` — `AWS::OpenSearchServerless::SecurityPolicy`

- Type: `network`.
- `AllowFromPublic: true` — the collection endpoint is reachable over the public internet (still protected by SigV4 IAM auth and the data access policy).
- Applies to both `collection` and `dashboard` resources.

  > For production workloads that need private connectivity, replace `AllowFromPublic: true` with `SourceVPCEs: [<vpc-endpoint-ids>]` and provision an AOSS VPC endpoint.

#### `DataAccessPolicy` — `AWS::OpenSearchServerless::AccessPolicy`

- Type: `data`.
- Grants index-level (`CreateIndex`, `DeleteIndex`, `UpdateIndex`, `DescribeIndex`, `ReadDocument`, `WriteDocument`) and collection-level (`CreateCollectionItems`, `DeleteCollectionItems`, `UpdateCollectionItems`, `DescribeCollectionItems`) permissions to three principals:
  1. `LambdaExecutionRole` (so the Lambdas can eventually read/write documents if you extend them).
  2. `BedrockKBRole` (so Bedrock can create and populate the vector index during ingestion).
  3. **A hardcoded principal** `arn:aws:sts::<account>:assumed-role/Admin/abhagam-Isengard`. This was included so the original developer's console session could inspect the index directly. It does not block deployment in a different account, but you should remove it or replace it with your own admin principal before using this template in a shared or production environment.

#### `DocumentCollection` — `AWS::OpenSearchServerless::Collection`

- Type: `VECTORSEARCH` (required for use as a Bedrock KB vector store).
- `DependsOn` all three AOSS policies above (encryption, network, and data access policies must exist before the collection).

### Outputs (exports)

Every output is exported as `${AWS::StackName}-<key>` so Stack 2 can import it with `Fn::ImportValue`.

| Export name | Value | Consumer in Stack 2 |
|---|---|---|
| `<stack>-CollectionArn` | `!GetAtt DocumentCollection.Arn` | `DocumentKnowledgeBase.StorageConfiguration.OpensearchServerlessConfiguration.CollectionArn` |
| `<stack>-CollectionEndpoint` | `!GetAtt DocumentCollection.CollectionEndpoint` | `VectorIndex.CollectionEndpoint` |
| `<stack>-LambdaRoleArn` | `!GetAtt LambdaExecutionRole.Arn` | Execution role for both Lambdas |
| `<stack>-BedrockKBRoleArn` | `!GetAtt BedrockKBRole.Arn` | `DocumentKnowledgeBase.RoleArn` |

---

## Stack 2 — `stack-2-kb.yaml`

**Purpose.** Everything above the AOSS collection: the vector index inside it, the Bedrock Knowledge Base and data source, the two Lambdas, the S3 buckets, and the S3 event notifications.

**Parameters.**

| Name | Type | Purpose |
|---|---|---|
| `AossStackName` | `String` | Name of the Stack 1 stack. Used in every `Fn::ImportValue` in this template. |

### Resources

#### `DocumentParserLambda` — `AWS::Lambda::Function`

- **Name.** `${AWS::StackName}-<stackUUID>-document-parser`.
- **Runtime.** `python3.14`. **Handler.** `index.lambda_handler`. **Timeout.** 300 seconds. **Memory.** 1024 MB.
- **Role.** Imported `${AossStackName}-LambdaRoleArn`.
- **Code.** Inline (`ZipFile`). The handler:
  1. Reads `bucket` and `object.key` from the S3 event.
  2. Calls `textract.start_document_analysis` with `FeatureTypes=[LAYOUT, TABLES, FORMS]`.
  3. Polls `get_document_analysis(JobId=...)` every 5 seconds until status is `SUCCEEDED` or `FAILED`.
  4. On `SUCCEEDED`, paginates every result page (following `NextToken`) and collects every block whose `BlockType == "LINE"`.
  5. Writes `parsed_files/<name>_parsed.json` back to the same bucket as `{"document": ..., "extracted_text": [...]}`.
  6. Returns 200 on success, 500 on failure.

#### `KBParserLambda` — `AWS::Lambda::Function`

- **Name.** `${AWS::StackName}-<stackUUID>-kb-parser`.
- **Runtime.** `python3.14`. **Handler.** `index.lambda_handler`. **Timeout.** 300 seconds. **Memory.** 1024 MB.
- **Role.** Imported `${AossStackName}-LambdaRoleArn`.
- **Code.** Inline. The handler:
  1. Reads the JSON produced by `DocumentParserLambda`.
  2. Builds a prompt that asks Amazon Nova Micro to reformat the content into a structured, error-free document tagged with the original file name.
  3. Calls `bedrock-runtime.converse` with `modelId = amazon.nova-micro-v1:0`, `maxTokens = 6000`, `temperature = 0.5`, `topP = 0.9`.
  4. Writes the model's text output to `parsed_kb_documents/<name>.txt`.
  5. Bubbles up any `ClientError` from the Bedrock call.

  > The Bedrock client is created with `region_name="us-east-1"` hardcoded. If you deploy to a different region, either change this literal to `os.environ['AWS_REGION']` or make sure `us-east-1` still has Nova Micro model access enabled for the deployment account.

#### `DocumentParserS3Permission` / `KBParserS3Permission` — `AWS::Lambda::Permission`

Both grant `lambda:InvokeFunction` to `s3.amazonaws.com`, scoped by `SourceArn` (to the documents bucket) and `SourceAccount` (the deploying account). CloudFormation requires these permissions to exist before the bucket's `NotificationConfiguration` references the Lambdas — hence `DocumentBucket` has `DependsOn: [DocumentParserS3Permission, KBParserS3Permission]`.

#### `AccessLogsBucket` — `AWS::S3::Bucket`

- Name: `access-logs-${AWS::StackName}-<stackUUID>-<account>`.
- Versioning enabled.
- KMS server-side encryption.
- Self-logs to prefix `self-access-logs/`.
- `PublicAccessBlockConfiguration` fully blocked.
- `OwnershipControls: BucketOwnerPreferred`.

#### `DocumentBucket` — `AWS::S3::Bucket`

- Name: `documents-${AWS::StackName}-<stackUUID>-<account>`.
- Versioning enabled, KMS SSE, PAB fully blocked.
- Server access logs go to `AccessLogsBucket` under `document-bucket-access-logs/`.
- `NotificationConfiguration.LambdaConfigurations` — three event rules:

  | Prefix | Suffix | Target |
  |---|---|---|
  | `raw_files/` | `.pdf` | `DocumentParserLambda` |
  | `raw_files/` | `.png` | `DocumentParserLambda` |
  | `parsed_files/` | `.json` | `KBParserLambda` |

  These rules are what wire the whole pipeline together — no orchestrator, no queue.

  > Because both `raw_files/*.pdf` and `raw_files/*.png` map to the same target, you could also handle other formats (JPEG, TIFF) by adding rows here. Textract supports those, but the current template does not.

#### `VectorIndex` — `AWS::OpenSearchServerless::Index`

- **Collection endpoint.** Imported `${AossStackName}-CollectionEndpoint`.
- **Index name.** `document_index`.
- **Settings.** `Knn: true`, `KnnAlgoParamEfSearch: 512`.
- **Mappings.**

  | Field | Type | Notes |
  |---|---|---|
  | `vector_field` | `knn_vector` | `Dimension: 1536` (Titan Text v1). `Method: hnsw` on `Engine: faiss` with `SpaceType: l2`, `EfConstruction: 512`, `M: 16`. |
  | `text_chunk` | `text` | The chunk text Bedrock stores alongside the embedding. |
  | `metadata` | `text`, `Index: false` | Bedrock-managed metadata (source URI, chunk ID). Stored but not searchable. |

  These field names must match the `FieldMapping` on the KB below (`VectorField`, `TextField`, `MetadataField`), otherwise Bedrock will refuse to start an ingestion job.

#### `DocumentKnowledgeBase` — `AWS::Bedrock::KnowledgeBase`

- **Name.** `${AWS::StackName}-<stackUUID>-kb`.
- **Role.** Imported `${AossStackName}-BedrockKBRoleArn`.
- **KB configuration.** `Type: VECTOR`, `EmbeddingModelArn: amazon.titan-embed-text-v1`.
- **Storage configuration.** `Type: OPENSEARCH_SERVERLESS`, pointing at the imported collection ARN and the `document_index` field mapping above.
- `DependsOn: VectorIndex` — the index must exist before the KB tries to attach to it.

#### `DocumentDataSource` — `AWS::Bedrock::DataSource`

- **Name.** `${AWS::StackName}-<stackUUID>-datasource`.
- **KB.** `!Ref DocumentKnowledgeBase`.
- **Data deletion policy.** `RETAIN` — deleting the data source or Knowledge Base does **not** delete the source S3 objects.
- **Source.** S3 configuration on `DocumentBucket`, `InclusionPrefixes: ['parsed_kb_documents/']`. Everything else in the bucket (raw files, parsed JSON) is ignored by the KB.

### Outputs

Consumed by the deployment script's post-deploy tests. Not exported (no cross-stack consumer).

| Output | Value |
|---|---|
| `DocumentBucketName` | `!Ref DocumentBucket` |
| `DocumentParserLambdaArn` | `!GetAtt DocumentParserLambda.Arn` |
| `KBParserLambdaArn` | `!GetAtt KBParserLambda.Arn` |
| `KnowledgeBaseId` | `!Ref DocumentKnowledgeBase` |
| `KnowledgeBaseArn` | `!GetAtt DocumentKnowledgeBase.KnowledgeBaseArn` |

---

## Cross-stack dependency graph

```
Stack 1                                   Stack 2
─────────────────────────────             ──────────────────────────────────────────
LambdaExecutionRole  ─── export ──── LambdaRoleArn  ── used by ──▶ DocumentParserLambda
                                                                   KBParserLambda

BedrockKBRole        ─── export ──── BedrockKBRoleArn ── used by ─▶ DocumentKnowledgeBase

DocumentCollection ──┬─ export ──── CollectionArn      ── used by ─▶ DocumentKnowledgeBase
                     └─ export ──── CollectionEndpoint ── used by ─▶ VectorIndex
```

Because Stack 2 uses `Fn::ImportValue` for all four values, Stack 1 cannot be deleted while Stack 2 exists — CloudFormation will refuse to delete an exported value that another stack references. Follow the teardown order in [deployment.md](./deployment.md#teardown).

## Security posture summary

- Both S3 buckets: KMS SSE, versioning on, public access fully blocked, access-logged.
- IAM roles: scoped to specific model ARNs and to bucket name prefixes (`documents-*-<account>`). Textract is the only wildcard resource because Textract does not support resource-level ARNs.
- Bedrock KB role trust policy: uses `aws:SourceAccount` + `aws:SourceArn` conditions to prevent cross-account confused-deputy attacks.
- AOSS: `AllowFromPublic: true` on the network policy — swap to a VPC endpoint for production. The hardcoded `abhagam-Isengard` principal on the data access policy should also be removed for production.
