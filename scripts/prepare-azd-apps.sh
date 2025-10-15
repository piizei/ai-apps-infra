#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
AZD_PROJECT_DIR=${AZD_PROJECT_DIR:-"$REPO_ROOT/apps-azd"}

if [[ ! -f "$AZD_PROJECT_DIR/azure.yaml" ]]; then
  echo "Unable to locate azure.yaml in $AZD_PROJECT_DIR. Set AZD_PROJECT_DIR to your azd project directory and retry." >&2
  exit 1
fi

log_progress() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

azd_cmd() {
  # Prevent MSYS from rewriting arguments like "/subscriptions/..." into "C:/Program Files/..." when running Windows binaries.
  if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
    (cd "$AZD_PROJECT_DIR" && MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' azd "$@")
  else
    (cd "$AZD_PROJECT_DIR" && azd "$@")
  fi
}

ensure_env_file() {
  if [[ ! -d "$AZD_ENV_DIR" ]]; then
    mkdir -p "$AZD_ENV_DIR"
  fi
  if [[ ! -f "$AZD_ENV_FILE" ]]; then
    touch "$AZD_ENV_FILE"
  fi
}

azd_env_set() {
  local key="$1"
  local value="${2:-}"
  ensure_env_file
  "$PYTHON_BIN" - <<'PYCODE' "$AZD_ENV_FILE" "$key" "$value"
import re
import sys

env_path, key, value = sys.argv[1:4]

try:
    with open(env_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

escaped = value.replace('\\', '\\\\').replace('"', '\\"')
new_line = f"{key}=\"{escaped}\"\n"
pattern = re.compile(rf"^{re.escape(key)}=")

updated = False
result = []
for line in lines:
    if pattern.match(line):
        if not updated:
            result.append(new_line)
            updated = True
    else:
        result.append(line)

if not updated:
    result.append(new_line)

with open(env_path, 'w', encoding='utf-8') as f:
    for line in result:
        if line.endswith('\n'):
            f.write(line)
        else:
            f.write(line + '\n')
PYCODE
}

ensure_config_file() {
  if [[ ! -d "$AZD_CONFIG_DIR" ]]; then
    mkdir -p "$AZD_CONFIG_DIR"
  fi
  if [[ ! -f "$AZD_CONFIG_FILE" ]]; then
    printf '{\n  "name": "%s"\n}\n' "$AZD_ENV_NAME" >"$AZD_CONFIG_FILE"
  fi
}

azd_infra_param_set() {
  local key="$1"
  local value="${2:-}"
  ensure_config_file
  if [[ -z "$value" ]]; then
    azd_infra_param_clear "$key"
    return
  fi
  "$PYTHON_BIN" - <<'PYCODE' "$AZD_CONFIG_FILE" "$key" "$value"
import json
import sys

config_path, key, value = sys.argv[1:4]
segments = [part for part in f"infra.parameters.{key}.value".split('.') if part]

try:
    with open(config_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

node = data
for segment in segments[:-1]:
    node = node.setdefault(segment, {})

node[segments[-1]] = value

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYCODE
}

azd_infra_param_clear() {
  local key="$1"
  ensure_config_file
  "$PYTHON_BIN" - <<'PYCODE' "$AZD_CONFIG_FILE" "$key"
import json
import sys

config_path, key = sys.argv[1:3]
segments = [part for part in f"infra.parameters.{key}.value".split('.') if part]

try:
    with open(config_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

stack = []
node = data
for segment in segments:
    if not isinstance(node, dict) or segment not in node:
        break
    stack.append((node, segment))
    node = node[segment]
else:
    parent, last = stack[-1]
    parent.pop(last, None)
    for parent, segment in reversed(stack[:-1]):
        child = parent.get(segment)
        if isinstance(child, dict) and not child:
            parent.pop(segment, None)
        else:
            break

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYCODE
}

PYTHON_BIN=${PYTHON_BIN:-python}
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=python3
  else
    echo "Python is required for case-insensitive deployment output lookup. Install Python or set PYTHON_BIN to a compatible interpreter." >&2
    exit 1
  fi
fi

normalize_value() {
  local value="$1"
  # Strip Windows CR characters and control whitespace while preserving inner characters like '-'
  value="${value//$'\r'/}"
  value="${value//$'\n'/}"
  value="${value//$'\t'/}"
  value="${value//$'\v'/}"
  value="${value//$'\f'/}"
  # Trim leading/trailing whitespace
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  # Normalize null-like sentinel values
  if [[ "$value" == "null" || "$value" == "None" ]]; then
    value=""
  fi
  printf '%s' "$value"
}

fetch_group_output() {
  local __var_name="$1"
  local __deployment="$2"
  local __output="$3"
  local __allow_empty="${4:-false}"
  local __raw_value
  local __status=0

  if ! __raw_value=$(az deployment group show -g "$RESOURCE_GROUP" -n "$__deployment" --query "properties.outputs.$__output.value" -o tsv 2>/dev/null); then
    __status=$?
    if [[ "$__allow_empty" != "true" ]]; then
      echo "Failed to query output '$__output' from deployment '$__deployment' in resource group '$RESOURCE_GROUP'." >&2
      exit $__status
    fi
    __raw_value=""
  fi

  __raw_value=$(normalize_value "$__raw_value")

  if [[ -z "$__raw_value" ]]; then
    local __outputs_json=""
    if __outputs_json=$(az deployment group show -g "$RESOURCE_GROUP" -n "$__deployment" --query "properties.outputs" -o json 2>/dev/null); then
      __raw_value=$(printf '%s' "$__outputs_json" | "$PYTHON_BIN" - <<'PYCODE' "$__output"
import json
import re
import sys

def normalize(name: str) -> str:
    return re.sub(r"[^0-9a-zA-Z]", "", name or "").lower()

target = normalize(sys.argv[1])
try:
    data = json.load(sys.stdin) or {}
except json.JSONDecodeError:
    data = {}

value = ""
for key, meta in data.items():
    if normalize(key) == target:
        candidate = meta.get("value")
        if isinstance(candidate, bool):
            value = str(candidate).lower()
        elif candidate is None:
            value = ""
        else:
            value = str(candidate)
        break

print(value)
PYCODE
)
      __raw_value=$(normalize_value "$__raw_value")
    fi
  fi

  if [[ -z "$__raw_value" && "$__allow_empty" != "true" ]]; then
    echo "Deployment '$__deployment' did not provide a value for output '$__output' in resource group '$RESOURCE_GROUP'." >&2
    exit 1
  fi

  printf -v "$__var_name" '%s' "$__raw_value"
}

fetch_group_parameter() {
  local __var_name="$1"
  local __deployment="$2"
  local __parameter="$3"
  local __allow_empty="${4:-false}"
  local __raw_value
  local __status=0

  if ! __raw_value=$(az deployment group show -g "$RESOURCE_GROUP" -n "$__deployment" --query "properties.parameters.$__parameter.value" -o tsv 2>/dev/null); then
    __status=$?
    if [[ "$__allow_empty" != "true" ]]; then
      echo "Failed to query parameter '$__parameter' from deployment '$__deployment' in resource group '$RESOURCE_GROUP'." >&2
      exit $__status
    fi
    __raw_value=""
  fi

  __raw_value=$(normalize_value "$__raw_value")

  if [[ -z "$__raw_value" ]]; then
    local __parameters_json=""
    if __parameters_json=$(az deployment group show -g "$RESOURCE_GROUP" -n "$__deployment" --query "properties.parameters" -o json 2>/dev/null); then
      __raw_value=$(printf '%s' "$__parameters_json" | "$PYTHON_BIN" - <<'PYCODE' "$__parameter"
import json
import re
import sys

def normalize(name: str) -> str:
    return re.sub(r"[^0-9a-zA-Z]", "", name or "").lower()

target = normalize(sys.argv[1])
try:
    data = json.load(sys.stdin) or {}
except json.JSONDecodeError:
    data = {}

value = ""
for key, meta in data.items():
    if normalize(key) == target:
        candidate = meta.get("value")
        if isinstance(candidate, bool):
            value = str(candidate).lower()
        elif candidate is None:
            value = ""
        else:
            value = str(candidate)
        break

print(value)
PYCODE
)
      __raw_value=$(normalize_value "$__raw_value")
    fi
  fi

  if [[ -z "$__raw_value" && "$__allow_empty" != "true" ]]; then
    echo "Deployment '$__deployment' returned an empty value for parameter '$__parameter' in resource group '$RESOURCE_GROUP'." >&2
    exit 1
  fi

  printf -v "$__var_name" '%s' "$__raw_value"
}

fetch_sub_output() {
  local __var_name="$1"
  local __deployment="$2"
  local __output="$3"
  local __allow_empty="${4:-false}"
  local __raw_value
  local __status=0

  if ! __raw_value=$(az deployment sub show -n "$__deployment" --query "properties.outputs.$__output.value" -o tsv 2>/dev/null); then
    __status=$?
    if [[ "$__allow_empty" != "true" ]]; then
      echo "Failed to query subscription deployment output '$__output' from '$__deployment'." >&2
      exit $__status
    fi
    __raw_value=""
  fi

  __raw_value=$(normalize_value "$__raw_value")

  if [[ -z "$__raw_value" && "$__allow_empty" != "true" ]]; then
    echo "Subscription deployment '$__deployment' did not provide a value for output '$__output'." >&2
    exit 1
  fi

  printf -v "$__var_name" '%s' "$__raw_value"
}

# Prepare azd environment variables from layered Bicep deployments to deploy the Apps layer with azd.
# Requirements: Azure CLI (az), Azure Developer CLI (azd), jq (optional).

usage() {
  cat <<EOF
Usage: $0 -e <env> -r <region> [-s <subscriptionId>] [-g <resourceGroup>] [--app-instance <name>]

If resource group is not provided, it will be read from the base deployment outputs (base-<env>).
This script will:
  - Query outputs from identity, paas, and env deployments
  - Create or select an azd environment named <env>
  - Set azd environment variables used by the Apps layer

Examples:
  $0 -e dev -r westeurope
  $0 -e dev -r westeurope -g rg-app-xxxxxx-dev --app-instance blue
EOF
}

ENV=""
REGION=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
APP_INSTANCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env) ENV="$2"; shift 2;;
    -r|--region) REGION="$2"; shift 2;;
    -s|--subscription) SUBSCRIPTION_ID="$2"; shift 2;;
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2;;
    --app-instance) APP_INSTANCE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

[[ -z "$ENV" || -z "$REGION" ]] && { echo "-e/--env and -r/--region are required"; usage; exit 1; }

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi

SUBSCRIPTION_ID=$(normalize_value "$SUBSCRIPTION_ID")

export AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

# Resolve RG from base deployment if not provided
if [[ -z "$RESOURCE_GROUP" ]]; then
  if ! RESOURCE_GROUP=$(az deployment sub show -n "base-$ENV" --query "properties.outputs.resourceGroupName.value" -o tsv 2>/dev/null); then
    echo "Failed to resolve resource group from subscription deployment base-$ENV." >&2
    exit 1
  fi
  RESOURCE_GROUP=$(normalize_value "$RESOURCE_GROUP")
fi

RESOURCE_GROUP=$(normalize_value "$RESOURCE_GROUP")

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Failed to resolve resource group. Pass -g or ensure base-$ENV deployment exists." >&2
  exit 1
fi

if ! az group exists --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Resource group '$RESOURCE_GROUP' does not exist in subscription $SUBSCRIPTION_ID. Deploy the base layer or pass -g." >&2
  exit 1
fi

BASE_SALT=""
fetch_sub_output BASE_SALT "base-$ENV" "salt" true

echo "Using RG=$RESOURCE_GROUP (subscription=$SUBSCRIPTION_ID, env=$ENV, region=$REGION)"

# Ensure required deployments exist
ensure_group_deployment() {
  local deployment_name="$1"
  local friendly_name="$2"

  if ! az deployment group show -g "$RESOURCE_GROUP" -n "$deployment_name" >/dev/null 2>&1; then
    echo "Deployment '$deployment_name' was not found in resource group $RESOURCE_GROUP." >&2
    echo "Please deploy the $friendly_name layer before running this script." >&2
    exit 1
  fi
}

ensure_group_deployment "paas-$ENV" "PaaS"
ensure_group_deployment "env-$ENV" "environment"

# Identity outputs
log_progress "Retrieving identity outputs from environment deployment"
fetch_group_output UAI_PRINCIPAL_ID "env-$ENV" "applicationIdentityPrincipalId" true
fetch_group_output UAI_CLIENT_ID "env-$ENV" "applicationIdentityClientId" true
fetch_group_output UAI_ID "env-$ENV" "applicationIdentityId" true

if [[ -z "$UAI_PRINCIPAL_ID" || -z "$UAI_CLIENT_ID" || -z "$UAI_ID" ]]; then
  log_progress "Falling back to identity deployment outputs"
  ensure_group_deployment "identity-$ENV" "identity"
  fetch_group_output UAI_PRINCIPAL_ID "identity-$ENV" "principalId"
  fetch_group_output UAI_CLIENT_ID "identity-$ENV" "clientId"
  fetch_group_output UAI_ID "identity-$ENV" "id"
fi

# PaaS outputs (allow empty for fallback resolution)
fetch_group_output OPENAI_ENDPOINT "paas-$ENV" "azureOpenAiEndpoint" true
fetch_group_output SEARCH_ENDPOINT "paas-$ENV" "azureAiSearchEndpoint" true
fetch_group_output PG_HOST "paas-$ENV" "postgresFqdn" true

if [[ -z "$OPENAI_ENDPOINT" ]]; then
  OPENAI_ACCOUNT_NAME=""
  fetch_group_parameter OPENAI_ACCOUNT_NAME "paas-$ENV" "openAIAccountName" true
  if [[ -z "$OPENAI_ACCOUNT_NAME" && -n "$BASE_SALT" ]]; then
    OPENAI_ACCOUNT_NAME="oai${BASE_SALT}"
  fi
  if [[ -n "$OPENAI_ACCOUNT_NAME" ]]; then
    if OPENAI_ENDPOINT=$(az cognitiveservices account show -g "$RESOURCE_GROUP" -n "$OPENAI_ACCOUNT_NAME" --query properties.endpoint -o tsv 2>/dev/null); then
      OPENAI_ENDPOINT=$(normalize_value "$OPENAI_ENDPOINT")
      if [[ -n "$OPENAI_ENDPOINT" ]]; then
        echo "Info: Using OpenAI endpoint resolved from account '$OPENAI_ACCOUNT_NAME'."
      fi
    fi
  fi
  if [[ -z "$OPENAI_ENDPOINT" ]]; then
    echo "Deployment 'paas-$ENV' does not expose azureOpenAiEndpoint and fallback resolution failed. Redeploy the PaaS layer to populate outputs or specify the endpoint manually." >&2
    exit 1
  fi
fi

if [[ -z "$SEARCH_ENDPOINT" ]]; then
  AZURE_SEARCH_NAME=""
  fetch_group_parameter AZURE_SEARCH_NAME "paas-$ENV" "azureSearchName" true
  if [[ -z "$AZURE_SEARCH_NAME" && -n "$BASE_SALT" ]]; then
    AZURE_SEARCH_NAME="azsearch-${BASE_SALT}"
  fi
  if [[ -n "$AZURE_SEARCH_NAME" ]]; then
    SEARCH_ENDPOINT="https://${AZURE_SEARCH_NAME}.search.windows.net"
    echo "Info: Using Search endpoint inferred from service '${AZURE_SEARCH_NAME}'."
  fi
  if [[ -z "$SEARCH_ENDPOINT" ]]; then
    echo "Deployment 'paas-$ENV' does not expose azureAiSearchEndpoint and fallback resolution failed. Redeploy the PaaS layer or provide the endpoint manually." >&2
    exit 1
  fi
fi

if [[ -z "$PG_HOST" ]]; then
  POSTGRE_NAME=""
  fetch_group_parameter POSTGRE_NAME "paas-$ENV" "postgreName" true
  if [[ -z "$POSTGRE_NAME" && -n "$BASE_SALT" ]]; then
    POSTGRE_NAME="postgre-${BASE_SALT}"
  fi
  if [[ -n "$POSTGRE_NAME" ]]; then
    if PG_HOST=$(az postgres flexible-server show -g "$RESOURCE_GROUP" -n "$POSTGRE_NAME" --query fullyQualifiedDomainName -o tsv 2>/dev/null); then
      PG_HOST=$(normalize_value "$PG_HOST")
      if [[ -n "$PG_HOST" ]]; then
        echo "Info: Using PostgreSQL host resolved from server '${POSTGRE_NAME}'."
      fi
    fi
  fi
  if [[ -z "$PG_HOST" ]]; then
    echo "Deployment 'paas-$ENV' does not expose postgresFqdn and fallback resolution failed. Redeploy the PaaS layer or set DATABASE_HOST manually." >&2
    exit 1
  fi
fi

# Env outputs
fetch_group_output ENV_ID "env-$ENV" "containerAppsEnvironmentId" true
fetch_group_output ENV_DOMAIN "env-$ENV" "containerAppsDefaultDomain" true
fetch_group_output ACR_LOGIN "env-$ENV" "acrLoginServer" true
fetch_group_output ACR_NAME "env-$ENV" "acrName" true
fetch_group_output ACR_ID "env-$ENV" "acrId" true
fetch_group_output APPINSIGHTS_CS "env-$ENV" "applicationInsightsConnectionString" true
fetch_group_output STORAGE_NAME "env-$ENV" "storageAccountName"
fetch_group_output BLOB_ENDPOINT "env-$ENV" "storageBlobEndpoint"
fetch_group_output CONTAINER_NAME "env-$ENV" "storageContainerName"
fetch_group_output QUEUE_NAME "env-$ENV" "queueName"
fetch_group_output DEV_QUEUE_NAME "env-$ENV" "devQueueName" true
fetch_group_output TOKEN_SAS "env-$ENV" "tokenStoreSasUrl"
fetch_group_parameter DEPLOY_DEV_QUEUE "env-$ENV" "deployDevelopmentQueue" true

ENV_APP_INSTANCE_PARAM=""
fetch_group_parameter ENV_APP_INSTANCE_PARAM "env-$ENV" "appInstance" true
RESOLVED_APP_INSTANCE="${ENV_APP_INSTANCE_PARAM:-}"
if [[ -z "$RESOLVED_APP_INSTANCE" && -n "$APP_INSTANCE" ]]; then
  RESOLVED_APP_INSTANCE="$APP_INSTANCE"
fi

if [[ -z "$ACR_NAME" ]]; then
  fetch_group_parameter ACR_NAME "env-$ENV" "acrName" true
fi

if [[ -z "$APPINSIGHTS_CS" ]]; then
  APPINSIGHTS_NAME=""
  fetch_group_parameter APPINSIGHTS_NAME "env-$ENV" "applicationInsightsName" true
  if [[ -z "$APPINSIGHTS_NAME" && -n "$BASE_SALT" ]]; then
    if [[ -z "$RESOLVED_APP_INSTANCE" ]]; then
      APPINSIGHTS_NAME="appi-${BASE_SALT}"
    else
      APPINSIGHTS_NAME="appi-${BASE_SALT}-${RESOLVED_APP_INSTANCE}"
    fi
  fi
  if [[ -n "$APPINSIGHTS_NAME" ]]; then
    if APPINSIGHTS_CS=$(az monitor app-insights component show --app "$APPINSIGHTS_NAME" -g "$RESOURCE_GROUP" --query properties.ConnectionString -o tsv 2>/dev/null); then
      APPINSIGHTS_CS=$(normalize_value "$APPINSIGHTS_CS")
      if [[ -n "$APPINSIGHTS_CS" ]]; then
        echo "Info: Using Application Insights connection string resolved from '$APPINSIGHTS_NAME'."
      fi
    fi
  fi
  if [[ -z "$APPINSIGHTS_CS" ]]; then
    echo "Deployment 'env-$ENV' does not expose applicationInsightsConnectionString and fallback resolution failed. Redeploy the env layer or provide the Application Insights resource name." >&2
    exit 1
  fi
fi

if [[ -z "$ACR_NAME" && -n "$BASE_SALT" ]]; then
  if [[ -z "$RESOLVED_APP_INSTANCE" ]]; then
    ACR_NAME="acr${BASE_SALT}"
  else
    ACR_NAME="acr${BASE_SALT}${RESOLVED_APP_INSTANCE}"
  fi
fi

if [[ -z "$ACR_NAME" ]]; then
  echo "Deployment 'env-$ENV' does not expose acrName and fallback resolution failed. Redeploy the env layer or provide the ACR name." >&2
  exit 1
fi

if [[ -z "$ACR_LOGIN" ]]; then
  if ACR_LOGIN=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query loginServer -o tsv 2>/dev/null); then
    ACR_LOGIN=$(normalize_value "$ACR_LOGIN")
    if [[ -n "$ACR_LOGIN" ]]; then
      echo "Info: Using ACR login server resolved from registry '$ACR_NAME'."
    fi
  fi
fi

if [[ -z "$ACR_LOGIN" ]]; then
  echo "Deployment 'env-$ENV' does not expose acrLoginServer and fallback resolution failed. Redeploy the env layer or ensure registry '$ACR_NAME' exists." >&2
  exit 1
fi

if [[ -z "$ACR_ID" ]]; then
  if ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null); then
    ACR_ID=$(normalize_value "$ACR_ID")
  fi
fi

CONTAINER_ENV_NAME=""
fetch_group_parameter CONTAINER_ENV_NAME "env-$ENV" "containerAppEnvName" true

if [[ -z "$CONTAINER_ENV_NAME" && -n "$BASE_SALT" ]]; then
  if [[ -z "$RESOLVED_APP_INSTANCE" ]]; then
    CONTAINER_ENV_NAME="env-${BASE_SALT}"
  else
    CONTAINER_ENV_NAME="env-${BASE_SALT}-${RESOLVED_APP_INSTANCE}"
  fi
fi

if [[ -n "$CONTAINER_ENV_NAME" && ( -z "$ENV_ID" || -z "$ENV_DOMAIN" ) ]]; then
  if ENV_DETAILS=$(az containerapp env show -g "$RESOURCE_GROUP" -n "$CONTAINER_ENV_NAME" --query "{id:id,defaultDomain:properties.defaultDomain}" -o tsv 2>/dev/null); then
    IFS=$'\t' read -r ENV_ID_FALLBACK ENV_DOMAIN_FALLBACK <<<"$ENV_DETAILS"
    ENV_ID_FALLBACK=$(normalize_value "${ENV_ID_FALLBACK:-}")
    ENV_DOMAIN_FALLBACK=$(normalize_value "${ENV_DOMAIN_FALLBACK:-}")
    if [[ -z "$ENV_ID" && -n "$ENV_ID_FALLBACK" ]]; then
      ENV_ID="$ENV_ID_FALLBACK"
      echo "Info: Using Container Apps environment ID resolved from '$CONTAINER_ENV_NAME'."
    fi
    if [[ -z "$ENV_DOMAIN" && -n "$ENV_DOMAIN_FALLBACK" ]]; then
      ENV_DOMAIN="$ENV_DOMAIN_FALLBACK"
      echo "Info: Using Container Apps default domain resolved from '$CONTAINER_ENV_NAME'."
    fi
  fi
fi

if [[ -z "$ENV_ID" ]]; then
  echo "Deployment 'env-$ENV' does not expose containerAppsEnvironmentId and fallback resolution failed. Redeploy the env layer or specify the environment name via --app-instance." >&2
  exit 1
fi

if [[ -z "$ENV_DOMAIN" ]]; then
  echo "Deployment 'env-$ENV' does not expose containerAppsDefaultDomain and fallback resolution failed. Redeploy the env layer or verify container apps environment accessibility." >&2
  exit 1
fi

# Create/select azd environment
AZD_ENV_NAME="$ENV"
AZD_CONFIG_DIR="$AZD_PROJECT_DIR/.azure/$AZD_ENV_NAME"
AZD_CONFIG_FILE="$AZD_CONFIG_DIR/config.json"
AZD_ENV_DIR="$AZD_CONFIG_DIR"
AZD_ENV_FILE="$AZD_ENV_DIR/.env"
if ! azd_cmd env get-values --environment "$AZD_ENV_NAME" >/dev/null 2>&1; then
  azd_cmd env new "$AZD_ENV_NAME" --subscription "$SUBSCRIPTION_ID" --location "$REGION" >/dev/null
fi

echo "Setting azd environment variables in '$AZD_ENV_NAME'..."
azd_env_set AZURE_ENV_NAME "$ENV"
azd_env_set AZURE_LOCATION "$REGION"
azd_env_set AZURE_SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
azd_env_set AZURE_RESOURCE_GROUP "$RESOURCE_GROUP"

# Identity and endpoints
azd_env_set APPLICATION_IDENTITY_PRINCIPAL_ID "$UAI_PRINCIPAL_ID"
azd_env_set APPLICATION_IDENTITY_CLIENT_ID "$UAI_CLIENT_ID"
azd_env_set APPLICATION_IDENTITY_ID "$UAI_ID"
azd_env_set AZURE_OPENAI_ENDPOINT "$OPENAI_ENDPOINT"
azd_env_set AZURE_AI_SEARCH_ENDPOINT "$SEARCH_ENDPOINT"
azd_infra_param_set applicationIdentityPrincipalId "$UAI_PRINCIPAL_ID"
azd_infra_param_set applicationIdentityClientId "$UAI_CLIENT_ID"
azd_infra_param_set applicationIdentityId "$UAI_ID"
azd_infra_param_set azureOpenAIEndpoint "$OPENAI_ENDPOINT"
azd_infra_param_set azureAiSearchEndpoint "$SEARCH_ENDPOINT"

# Env/infra
azd_env_set CONTAINERAPPS_ENV_ID "$ENV_ID"
azd_env_set CONTAINERAPPS_DEFAULT_DOMAIN "$ENV_DOMAIN"
azd_env_set APPLICATIONINSIGHTS_CONNECTION_STRING "$APPINSIGHTS_CS"
azd_env_set STORAGE_ACCOUNT_NAME "$STORAGE_NAME"
azd_env_set STORAGE_BLOB_ENDPOINT "$BLOB_ENDPOINT"
azd_env_set STORAGE_CONTAINER_NAME "$CONTAINER_NAME"
azd_env_set QUEUE_NAME "$QUEUE_NAME"
azd_infra_param_set containerAppsEnvironmentId "$ENV_ID"
azd_infra_param_set containerAppsDefaultDomain "$ENV_DOMAIN"
azd_infra_param_set applicationInsightsConnectionString "$APPINSIGHTS_CS"
azd_infra_param_set storageAccountName "$STORAGE_NAME"
azd_infra_param_set blobEndpoint "$BLOB_ENDPOINT"
azd_infra_param_set blobContainerName "$CONTAINER_NAME"
azd_infra_param_set queueName "$QUEUE_NAME"
if [[ "${DEPLOY_DEV_QUEUE,,}" == "true" ]]; then
  azd_env_set DEV_QUEUE_NAME "$DEV_QUEUE_NAME"
  azd_infra_param_set devQueueName "$DEV_QUEUE_NAME"
else
  azd_env_set DEV_QUEUE_NAME ""
  azd_infra_param_set devQueueName ""
fi
azd_env_set TOKEN_STORE_SAS_URL "$TOKEN_SAS"
azd_env_set ACR_LOGIN_SERVER "$ACR_LOGIN"
azd_env_set ACR_NAME "$ACR_NAME"
azd_env_set AZURE_CONTAINER_REGISTRY_ENDPOINT "$ACR_LOGIN"
azd_env_set AZURE_CONTAINER_REGISTRY_NAME "$ACR_NAME"
azd_infra_param_set tokenStoreSas "$TOKEN_SAS"
azd_infra_param_set acrLoginServer "$ACR_LOGIN"
azd_infra_param_set environmentName "$ENV"
azd_infra_param_set location "$REGION"
if [[ -n "$ACR_ID" ]]; then
  azd_env_set AZURE_CONTAINER_REGISTRY_ID "$ACR_ID"
fi

# Database
azd_env_set DATABASE_HOST "$PG_HOST"
azd_env_set DATABASE_NAME postgres
azd_env_set DATABASE_SCHEMA public
azd_infra_param_set databaseHost "$PG_HOST"

# Optional: app instance suffix for multiple ACA envs per shared PaaS
if [[ -n "$APP_INSTANCE" ]]; then
  azd_env_set APP_INSTANCE "$APP_INSTANCE"
fi

echo "Done. You can inspect values with: (cd $AZD_PROJECT_DIR && azd env get-values --environment $AZD_ENV_NAME)"
