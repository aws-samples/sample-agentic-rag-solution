#!/bin/sh

# -----------------------------------------------------------------------------
# custom-kb two-stack deployment script
#
# Stack 1 (stack-1-aoss.yaml): AOSS collection + IAM roles
#   Must complete fully before Stack 2 so the collection endpoint exists when
#   the CloudFormation EarlyValidation hook runs on Stack 2.
#
# Stack 2 (stack-2-kb.yaml): Vector index + Bedrock KB + Lambdas + S3
#   Imports CollectionEndpoint, CollectionArn, LambdaRoleArn, BedrockKBRoleArn
#   from Stack 1 via CloudFormation Exports.
#
# Usage:
#   ./custom_kb_deployment_setup.sh [OPTIONS]
#
# Options:
#   -r, --region        AWS region           (default: us-east-1)
#   -s, --stack1-name   Stack 1 name         (default: custom-kb-aoss)
#   -k, --stack2-name   Stack 2 name         (default: custom-kb-app)
#   -p, --profile       AWS CLI profile      (default: default)
#       --stack1-only   Deploy Stack 1 only
#       --stack2-only   Deploy Stack 2 only  (Stack 1 must already exist)
#       --test-only     Run post-deploy tests only (no deployment)
#   -h, --help          Show this help
#
# Examples:
#   ./custom_kb_deployment_setup.sh
#   ./custom_kb_deployment_setup.sh --region us-west-2
#   ./custom_kb_deployment_setup.sh --stack1-name my-aoss --stack2-name my-kb
#   ./custom_kb_deployment_setup.sh --profile prod --region us-east-1
#   ./custom_kb_deployment_setup.sh --stack1-only
#   ./custom_kb_deployment_setup.sh --test-only
# -----------------------------------------------------------------------------

log() {
    level=$1; msg=$2
    echo "[$level] $msg"
    [ "$level" = "ERROR" ] && exit 1
}

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; TESTS_FAILED=1; }

usage() {
    sed -n '/^# Usage:/,/^# ---/p' "$0" | grep "^#" | sed 's/^# \{0,2\}//'
    exit 0
}

# -----------------------------------------------------------------------------
# 1. Parse arguments
# -----------------------------------------------------------------------------
STACK1_NAME="custom-kb-aoss"
STACK2_NAME="custom-kb-app"
AWS_PROFILE="default"
DEPLOY_STACK1=1
DEPLOY_STACK2=1
TEST_ONLY=0
TESTS_FAILED=0

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--region)        AWS_REGION="$2";  shift 2 ;;
        -s|--stack1-name)   STACK1_NAME="$2"; shift 2 ;;
        -k|--stack2-name)   STACK2_NAME="$2"; shift 2 ;;
        -p|--profile)       AWS_PROFILE="$2"; shift 2 ;;
        --stack1-only)      DEPLOY_STACK2=0;  shift ;;
        --stack2-only)      DEPLOY_STACK1=0;  shift ;;
        --test-only)        DEPLOY_STACK1=0; DEPLOY_STACK2=0; TEST_ONLY=1; shift ;;
        -h|--help)          usage ;;
        *) log "ERROR" "Unknown option: $1. Use --help for usage." ;;
    esac
done

# -----------------------------------------------------------------------------
# 2. Resolve AWS credentials
# -----------------------------------------------------------------------------
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    log "INFO" "Loading credentials from profile: $AWS_PROFILE"
    if [ -f ~/.aws/credentials ]; then
        export AWS_ACCESS_KEY_ID=$(grep -A2 "\[$AWS_PROFILE\]" ~/.aws/credentials | grep aws_access_key_id | cut -d '=' -f 2 | tr -d ' ')
        export AWS_SECRET_ACCESS_KEY=$(grep -A2 "\[$AWS_PROFILE\]" ~/.aws/credentials | grep aws_secret_access_key | cut -d '=' -f 2 | tr -d ' ')
        AWS_SESSION_TOKEN=$(grep -A3 "\[$AWS_PROFILE\]" ~/.aws/credentials | grep aws_session_token | cut -d '=' -f 2 | tr -d ' ')
        [ -n "$AWS_SESSION_TOKEN" ] && export AWS_SESSION_TOKEN
    fi
fi
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    log "ERROR" "AWS credentials not found. Configure ~/.aws/credentials or set environment variables."
fi
log "INFO" "Credentials resolved (profile: $AWS_PROFILE)"

# -----------------------------------------------------------------------------
# 3. Set region
# -----------------------------------------------------------------------------
if [ -z "$AWS_REGION" ] && [ -f ~/.aws/config ]; then
    PROFILE_REGION=$(grep -A5 "\[profile $AWS_PROFILE\]\|\[default\]" ~/.aws/config | grep "^region" | head -1 | cut -d '=' -f 2 | tr -d ' ')
    [ -n "$PROFILE_REGION" ] && export AWS_REGION="$PROFILE_REGION" && log "INFO" "Region from config: $AWS_REGION"
fi
if [ -z "$AWS_REGION" ]; then
    export AWS_REGION=us-east-1
    log "INFO" "Region defaulting to $AWS_REGION"
else
    log "INFO" "Region: $AWS_REGION"
fi

# -----------------------------------------------------------------------------
# 4. Verify connectivity
# -----------------------------------------------------------------------------
aws s3 ls --profile "$AWS_PROFILE" > /dev/null 2>&1 || log "ERROR" "AWS connection failed."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "$AWS_PROFILE") || log "ERROR" "Failed to get account ID"
log "INFO" "Account ID: $ACCOUNT_ID  Region: $AWS_REGION"

# -----------------------------------------------------------------------------
# 5. Verify templates
# -----------------------------------------------------------------------------
STACK1_TEMPLATE="./resources/stack-1-aoss.yaml"
STACK2_TEMPLATE="./resources/stack-2-kb.yaml"

[ ! -f "$STACK1_TEMPLATE" ] && log "ERROR" "Template not found: $STACK1_TEMPLATE"
[ ! -f "$STACK2_TEMPLATE" ] && log "ERROR" "Template not found: $STACK2_TEMPLATE"
log "INFO" "Templates found: $STACK1_TEMPLATE  $STACK2_TEMPLATE"

# -----------------------------------------------------------------------------
# 6. Deploy Stack 1 — AOSS collection + IAM roles
# -----------------------------------------------------------------------------
if [ "$DEPLOY_STACK1" = "1" ]; then
    log "INFO" "=== Deploying Stack 1: $STACK1_NAME ==="
    aws cloudformation deploy \
        --template-file "$STACK1_TEMPLATE" \
        --stack-name "$STACK1_NAME" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE"
    [ $? -ne 0 ] && log "ERROR" "Stack 1 deployment failed. Check AWS Console for events."
    log "INFO" "Stack 1 deployed"
fi

# -----------------------------------------------------------------------------
# 7. Deploy Stack 2 — Vector index + KB + Lambdas + S3
# -----------------------------------------------------------------------------
if [ "$DEPLOY_STACK2" = "1" ]; then
    log "INFO" "=== Deploying Stack 2: $STACK2_NAME ==="
    aws cloudformation deploy \
        --template-file "$STACK2_TEMPLATE" \
        --stack-name "$STACK2_NAME" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --parameter-overrides AossStackName="$STACK1_NAME" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE"
    [ $? -ne 0 ] && log "ERROR" "Stack 2 deployment failed. Check AWS Console for events."
    log "INFO" "Stack 2 deployed"
fi

# -----------------------------------------------------------------------------
# 8. Post-deployment tests
# -----------------------------------------------------------------------------
log "INFO" "=== Running post-deployment tests ==="

# Test 1: Stack 1 is in a healthy state
STACK1_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK1_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].StackStatus" --output text 2>&1)
if echo "$STACK1_STATUS" | grep -qE "COMPLETE$"; then
    pass "Stack 1 status: $STACK1_STATUS"
else
    fail "Stack 1 status unexpected: $STACK1_STATUS"
fi

# Test 2: Stack 2 is in a healthy state
STACK2_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK2_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].StackStatus" --output text 2>&1)
if echo "$STACK2_STATUS" | grep -qE "COMPLETE$"; then
    pass "Stack 2 status: $STACK2_STATUS"
else
    fail "Stack 2 status unexpected: $STACK2_STATUS"
fi

# Test 3: Stack 1 exports are present
for EXPORT in CollectionArn CollectionEndpoint LambdaRoleArn BedrockKBRoleArn; do
    VALUE=$(aws cloudformation list-exports \
        --region "$AWS_REGION" --profile "$AWS_PROFILE" \
        --query "Exports[?Name=='${STACK1_NAME}-${EXPORT}'].Value" \
        --output text 2>&1)
    if [ -n "$VALUE" ] && [ "$VALUE" != "None" ]; then
        pass "Export ${STACK1_NAME}-${EXPORT} = $VALUE"
    else
        fail "Export ${STACK1_NAME}-${EXPORT} is missing or empty"
    fi
done

# Test 4: AOSS collection is ACTIVE
COLLECTION_ARN=$(aws cloudformation list-exports \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Exports[?Name=='${STACK1_NAME}-CollectionArn'].Value" \
    --output text 2>&1)
COLLECTION_ID=$(echo "$COLLECTION_ARN" | rev | cut -d'/' -f1 | rev)
COLLECTION_STATUS=$(aws opensearchserverless batch-get-collection \
    --ids "$COLLECTION_ID" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "collectionDetails[0].status" --output text 2>&1)
if [ "$COLLECTION_STATUS" = "ACTIVE" ]; then
    pass "AOSS collection status: ACTIVE"
else
    fail "AOSS collection status: $COLLECTION_STATUS (expected ACTIVE)"
fi

# Test 5: Bedrock KB is ACTIVE
KB_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK2_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" \
    --output text 2>&1)
KB_STATUS=$(aws bedrock-agent get-knowledge-base \
    --knowledge-base-id "$KB_ID" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "knowledgeBase.status" --output text 2>&1)
if [ "$KB_STATUS" = "ACTIVE" ]; then
    pass "Bedrock KB ($KB_ID) status: ACTIVE"
else
    fail "Bedrock KB ($KB_ID) status: $KB_STATUS (expected ACTIVE)"
fi

# Test 6: Documents S3 bucket exists
BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK2_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].Outputs[?OutputKey=='DocumentBucketName'].OutputValue" \
    --output text 2>&1)
aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "Documents bucket exists: $BUCKET_NAME"
else
    fail "Documents bucket not found: $BUCKET_NAME"
fi

# Test 7: Lambda functions exist and are active
for LAMBDA_KEY in DocumentParserLambdaArn KBParserLambdaArn; do
    LAMBDA_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$STACK2_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
        --query "Stacks[0].Outputs[?OutputKey=='${LAMBDA_KEY}'].OutputValue" \
        --output text 2>&1)
    LAMBDA_NAME=$(echo "$LAMBDA_ARN" | rev | cut -d':' -f1 | rev)
    LAMBDA_STATE=$(aws lambda get-function \
        --function-name "$LAMBDA_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
        --query "Configuration.State" --output text 2>&1)
    if [ "$LAMBDA_STATE" = "Active" ]; then
        pass "Lambda $LAMBDA_NAME state: Active"
    else
        fail "Lambda $LAMBDA_NAME state: $LAMBDA_STATE (expected Active)"
    fi
done

# -----------------------------------------------------------------------------
# 9. Print outputs
# -----------------------------------------------------------------------------
echo ""
log "INFO" "=== Stack 1 outputs ($STACK1_NAME) ==="
aws cloudformation describe-stacks \
    --stack-name "$STACK1_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output table

log "INFO" "=== Stack 2 outputs ($STACK2_NAME) ==="
aws cloudformation describe-stacks \
    --stack-name "$STACK2_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" --output table

# -----------------------------------------------------------------------------
# 10. Test summary
# -----------------------------------------------------------------------------
echo ""
if [ "$TESTS_FAILED" = "0" ]; then
    log "INFO" "All tests passed."
else
    log "ERROR" "One or more tests failed. Review output above."
fi
