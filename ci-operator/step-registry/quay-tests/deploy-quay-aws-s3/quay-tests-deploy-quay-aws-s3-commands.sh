#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

#Create AWS S3 Storage Bucket
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_AWS_S3_BUCKET="quayprowci$RANDOM"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

mkdir -p QUAY_AWS && cd QUAY_AWS
cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}

variable "aws_bucket" {
  default = "quayaws"
}
EOF

cat >>create_aws_bucket.tf <<EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${QUAY_AWS_ACCESS_KEY}"
  secret_key = "${QUAY_AWS_SECRET_KEY}"
}

resource "aws_s3_bucket" "quayaws" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "quayaws" {
  bucket = aws_s3_bucket.quayaws.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayaws]

  bucket = aws_s3_bucket.quayaws.id
  acl    = "private"
}
EOF

echo "quay aws s3 bucket name is ${QUAY_AWS_S3_BUCKET}"
export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
terraform init
terraform apply -auto-approve || true

#Share Terraform Var and Terraform Directory
echo "${QUAY_AWS_S3_BUCKET}" > ${SHARED_DIR}/QUAY_AWS_S3_BUCKET
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}

#Deploy Quay Operator to OCP namespace 'quay-enterprise'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay-enterprise
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  targetNamespaces:
  - quay-enterprise
EOF

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

for _ in {1..60}; do
  CSV=$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n quay-enterprise get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  sleep 10
done
echo "Quay Operator is deployed successfully"

#Deploy Quay, here disable monitoring component
cat >>config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_AUTO_PRUNE: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
PERMANENTLY_DELETE_TAGS: true
RESET_CHILD_MANIFEST_EXPIRATION: true
FEATURE_PROXY_STORAGE: true
FEATURE_SUPERUSER_CONFIGDUMP: true
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
SUPER_USERS:
  - quay
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - S3Storage
    - s3_bucket: $QUAY_AWS_S3_BUCKET
      storage_path: /quay
      s3_access_key: $QUAY_AWS_ACCESS_KEY
      s3_secret_key: $QUAY_AWS_SECRET_KEY
      host: s3.us-east-2.amazonaws.com
      s3_region: us-east-2
FEATURE_ANONYMOUS_ACCESS: true
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_USERNAME_CONFIRMATION: false
AUTHENTICATION_TYPE: Database
FEATURE_LISTEN_IP_VERSION: IPv4
REPO_MIRROR_ROLLBACK: false
AUTOPRUNE_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1
DEFAULT_TAG_EXPIRATION: 2w
TAG_EXPIRATION_OPTIONS:
  - 2w
  - 1d
EOF

oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: horizontalpodautoscaler
    managed: true
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: true
  - kind: route
    managed: true
EOF

for _ in {1..60}; do
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    oc -n quay-enterprise get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true
    quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
    curl -k -X POST $quay_route/api/v1/user/initialize --header 'Content-Type: application/json' \
         --data '{ "username": "'$QUAY_USERNAME'", "password": "'$QUAY_PASSWORD'", "email": "'$QUAY_EMAIL'", "access_token": true }' | jq '.access_token' | tr -d '"' | tr -d '\n' > "$SHARED_DIR"/quay_oauth2_token || true
    exit 0
  fi
  sleep 15
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
