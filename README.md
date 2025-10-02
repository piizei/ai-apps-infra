# Layered Bicep Deployment

This folder provides subscription- and resource group-scoped Bicep templates to deploy the environment in layers so that frequent changes to container apps can be deployed quickly without touching base networking or PaaS resources.

Key change: Each layer computes a short salt deterministically from `(subscriptionId, projectName, environmentName)` and uses consistent resource names (for example `vnet-<salt>`, `containerapp-subnet`, `pe-subnet`). Later layers reference the VNet and subnets by name via `existing` resources—no more passing subnet IDs or salt between steps.

Layers:
- Base (subscription scope): Virtual network, subnets, and resource group. Always private networking.
- Identity (resource group): User-assigned managed identity for container apps.
- PaaS (resource group): PostgreSQL Flexible Server, Azure OpenAI, Azure AI Search with private endpoints and private DNS.
- Env (resource group): Log Analytics, Application Insights, Storage (blob/queues/files + Event Grid), ACR, ACA managed environment, private DNS for ACA when internal.
- Apps (resource group): Container Apps (frontend, worker, mcp) pointing at the existing environment/services. Deployed via the `apps-azd/azure.yaml` azd project using the shared outputs.
- Full (subscription scope): Convenience orchestrator that wires all layers end-to-end.

## Parameters shared across layers
- environmentName, projectName, location (tags default automatically)
- You can override default names if needed (`vnetName`, `containerAppSubnetName`, `privateEndpointSubnetName`), otherwise the deterministic defaults are used.
- Identity outputs (principalId, clientId, id) are passed to PaaS and Apps.

## Deploy base (subscription scope)
```bash
export REGION="swedencentral"
export ENV="dev"

az deployment sub create \
  --name base-$ENV \
  --location "$REGION" \
  --template-file infrastructure/layers/main.base.bicep \
  --parameters environmentName="$ENV" location="$REGION" projectName="app"

# Get the resource group created by Base for subsequent group-scope deployments
export RG=$(az deployment sub show -n base-$ENV --query "properties.outputs.resourceGroupName.value" -o tsv)
```

## Deploy identity (resource group)
```bash
az deployment group create \
  --name identity-$ENV \
  --resource-group "$RG" \
  --template-file infrastructure/layers/main.identity.bicep \
  --parameters environmentName="$ENV" projectName="app"

export UAI_PRINCIPAL_ID=$(az deployment group show -g "$RG" -n identity-$ENV --query "properties.outputs.principalId.value" -o tsv)
export UAI_CLIENT_ID=$(az deployment group show -g "$RG" -n identity-$ENV --query "properties.outputs.clientId.value" -o tsv)
export UAI_ID=$(az deployment group show -g "$RG" -n identity-$ENV --query "properties.outputs.id.value" -o tsv)
```

## Deploy PaaS (resource group)
```bash
# Requires: PG_ADMIN_PASSWORD set in your shell
az deployment group create \
  --name paas-$ENV \
  --resource-group "$RG" \
  --template-file infrastructure/layers/main.paas.bicep \
  --parameters environmentName="$ENV" projectName="app" \
               applicationIdentityPrincipalId="$UAI_PRINCIPAL_ID" \
               applicationIdentityClientId="$UAI_CLIENT_ID" \
               applicationIdentityId="$UAI_ID" \
               pgAdminPassword="$PG_ADMIN_PASSWORD"

export OPENAI_ENDPOINT=$(az deployment group show -g "$RG" -n paas-$ENV --query "properties.outputs.azureOpenAiEndpoint.value" -o tsv)
export SEARCH_ENDPOINT=$(az deployment group show -g "$RG" -n paas-$ENV --query "properties.outputs.azureAiSearchEndpoint.value" -o tsv)
export PG_HOST=$(az deployment group show -g "$RG" -n paas-$ENV --query "properties.outputs.postgresFqdn.value" -o tsv)

# The identity client ID is required for the PaaS and Apps layers.
```

### PaaS layer (`main.paas.bicep`)

Parameters:

- `environmentName`: Name of the environment (e.g., dev, test, prod).
- `projectName`: Name of the project.
- `location`: Azure region where resources will be deployed.
- `applicationIdentityPrincipalId`: Principal ID of the user-assigned managed identity.
- `applicationIdentityId`: Resource ID of the user-assigned managed identity.
- `applicationIdentityClientId`: application (client) ID of the user-assigned managed identity. Required for configuring Microsoft Entra administrator on PostgreSQL.
- `pgAdminPassword`: Password for the PostgreSQL admin user.

Outputs:

- `azureOpenAiEndpoint`: The endpoint for Azure OpenAI.
- `azureAiSearchEndpoint`: The endpoint for Azure AI Search.
- `postgresFqdn`: The fully qualified domain name of the PostgreSQL server.
- `azureOpenAiAccountId`: The resource ID for the Azure OpenAI account.
- `azureAiSearchId`: The resource ID for the Azure AI Search service.

## Deploy Env (resource group)
```bash
az deployment group create \
  --name env-$ENV \
  --resource-group "$RG" \
  --template-file infrastructure/layers/main.env.bicep \
  --parameters environmentName="$ENV" projectName="app" \
               useWorkloadProfiles=true publicContainerApps=true \
               appInstance="${APP_INSTANCE:-}"

export ENV_ID=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.containerAppsEnvironmentId.value" -o tsv)
export ENV_DOMAIN=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.containerAppsDefaultDomain.value" -o tsv)
export ACR_LOGIN=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.acrLoginServer.value" -o tsv)
export ACR_ID=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.acrId.value" -o tsv)
export APPINSIGHTS_CS=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.applicationInsightsConnectionString.value" -o tsv)
export STORAGE_NAME=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.storageAccountName.value" -o tsv)
export BLOB_ENDPOINT=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.storageBlobEndpoint.value" -o tsv)
export CONTAINER_NAME=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.storageContainerName.value" -o tsv)
export QUEUE_NAME=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.queueName.value" -o tsv)
export TOKEN_SAS=$(az deployment group show -g "$RG" -n env-$ENV --query "properties.outputs.tokenStoreSasUrl.value" -o tsv)
```

## Deploy Apps with azd
```bash
# Populate azd environment variables from the layered deployments (requires identity, PaaS, and env layers to exist)
./scripts/prepare-azd-apps.sh -e "$ENV" -r "$REGION" -s "$SUBSCRIPTION_ID" --app-instance "${APP_INSTANCE:-}"

# Deploy the container apps using azd (builds images and pushes to the shared ACR)
cd apps-azd
azd deploy
```

The `prepare-azd-apps.sh` script populates the azd environment with the outputs from the base, identity, PaaS, and env deployments so that the `apps-azd/azure.yaml` project can reuse the shared resources. Use `azd up` for the first deployment (provisions secrets in the Container Apps) and `azd deploy` for subsequent image updates.

The azd project contains three container-app services (`frontend`, `worker`, `mcp`). Each service ships with a minimal Python-based container that you can replace with your own source and Dockerfile. During deployment azd builds the images, pushes them into the shared ACR, and supplies the resulting image tags to `main.apps.bicep`.

To wipe the container apps, run `azd down` from `apps-azd/` (shared infrastructure layers remain intact).

## Clean up the environment

Make sure the same shell session still has `ENV`, `REGION`, and `RG` exported (see Base layer section for how to recover them if needed).

1. Tear down the container apps (safe to rerun even if already removed):

  ```bash
  cd apps-azd
  azd down
  cd -
  ```

2. Delete the shared resource group created by the Base layer. This removes the identity, PaaS, and env resources alongside the container apps infrastructure:

  ```bash
  az group delete \
    --name "$RG" \
    --yes --no-wait
  ```

3. (Optional) Remove the stored deployment records so `az deployment list` stays tidy:

  ```bash
  for scope in identity paas env; do
    az deployment group delete \
     --resource-group "$RG" \
     --name "${scope}-$ENV" \
     || true
  done

  az deployment sub delete --name base-$ENV || true
  az deployment sub delete --name full-$ENV || true
  ```

Deleting the resource group does not automatically remove Azure Container Registry images; purge them separately if required.

## Deploy Full (optional convenience)
```bash
az deployment sub create \
  --name full-$ENV \
  --location "$REGION" \
  --template-file infrastructure/layers/main.full.bicep \
  --parameters environmentName="$ENV" location="$REGION" projectName="app" \
               pgAdminPassword="$PG_ADMIN_PASSWORD" \
               frontendImage="$FRONTEND_IMAGE" workerImage="$WORKER_IMAGE" mcpImage="$MCP_IMAGE"
```

Notes:
- Private links and VNet usage are enforced in these templates. Later layers look up `vnet-<salt>` and its subnets by default. If you change names in Base, pass the same names to PaaS/Env via `vnetName`, `containerAppSubnetName`, and `privateEndpointSubnetName`.
- The Apps layer is designed for frequent redeploys; it doesn’t modify networking or PaaS resources.
- Ensure your account has permission to create role assignments used by these templates.