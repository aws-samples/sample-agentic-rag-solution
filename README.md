# Sample Agentic RAG Solution

A serverless customization layer for Amazon Bedrock Knowledge Bases. Instead of pointing a Knowledge Base directly at raw documents, this solution runs each document through Amazon Textract (OCR) and Amazon Nova Micro (LLM reformatting) first — so a wider variety of inputs (including scanned PDFs and handwritten images) end up as clean, retrieval-friendly text before they are embedded and indexed.

## What gets deployed

Two CloudFormation stacks:

- **Stack 1** — OpenSearch Serverless vector collection + IAM roles.
- **Stack 2** — Two Lambda functions (Textract parser, Nova Micro reformatter), an S3 documents bucket with event notifications, an OpenSearch vector index, a Bedrock Knowledge Base, and a Bedrock S3 data source.

Data flow:

```
raw_files/*.pdf|.png ── S3 event ──▶ DocumentParserLambda ── Textract ─▶ parsed_files/*.json
                                                                              │
                                                        S3 event ─────────────┘
                                                              │
                                                              ▼
                                                       KBParserLambda ── Nova Micro ─▶ parsed_kb_documents/*.txt
                                                                              │
                                                                  Bedrock KB ingestion job
                                                                              │
                                                                              ▼
                                                                    OpenSearch vector index
```

## Quick start

```bash
cd custom-knowldegebase
bash custom_kb_deployment_setup.sh
```

The script deploys both stacks, runs seven post-deploy checks, and prints stack outputs. See [`docs/deployment.md`](./docs/deployment.md) for options (custom region, profile, stack names, partial deployment).

Before running, make sure `amazon.titan-embed-text-v1` and `amazon.nova-micro-v1:0` are enabled in your Bedrock model access page for the target region.

## Documentation

| Document | What it covers |
|---|---|
| [Architecture](./docs/architecture.md) | System overview, components, data flow, and design rationale. |
| [Deployment guide](./docs/deployment.md) | Prerequisites, deployment script options, teardown, and troubleshooting. |
| [Infrastructure reference](./docs/infrastructure.md) | Every resource in both CloudFormation templates, with IAM, S3, AOSS, Lambda, and Bedrock details. |
| [Usage guide](./docs/usage.md) | Uploading documents, triggering ingestion, querying the Knowledge Base, and adding new file types. |

## Repository layout

```
.
├── README.md                       ← you are here
├── LICENSE                         MIT-0
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── docs/                           Documentation (see the table above)
│   ├── architecture.md
│   ├── deployment.md
│   ├── infrastructure.md
│   └── usage.md
└── custom-knowldegebase/
    ├── ReadMe.md
    ├── custom_kb_deployment_setup.sh   Two-stack deployment helper
    ├── resources/
    │   ├── stack-1-aoss.yaml           AOSS collection + IAM roles
    │   └── stack-2-kb.yaml             KB + Lambdas + S3 + vector index
    └── usecase/                        Sample documents for testing
        ├── P_1-Sample.1.pdf
        ├── employee_enrollment.pdf
        ├── handwritten.pdf
        ├── service_providers.pdf
        └── test_handwritten_document.png
```

## Prerequisites

- AWS CLI v2 configured with credentials for the target account.
- A region that supports Bedrock, Bedrock Knowledge Bases, OpenSearch Serverless, and Textract async document analysis (default: `us-east-1`).
- Bedrock model access granted for `amazon.titan-embed-text-v1` and `amazon.nova-micro-v1:0`.
- IAM permissions equivalent to CloudFormation full access plus IAM role, S3, Lambda, OpenSearch Serverless, and Bedrock write access.

Full checklist and troubleshooting in [`docs/deployment.md`](./docs/deployment.md).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

This project is licensed under the MIT-0 License — see [LICENSE](./LICENSE).
