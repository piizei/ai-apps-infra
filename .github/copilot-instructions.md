# AI coding agent guide for this repo

This workspace is an Azure infrastructure-only project using Bicep. It defines the full environment for a 3-service app ('app') deployed to Azure Container Apps with managed identity, data services, networking, and optional private endpoints.

## Architecture at a glance
- Orchestrator: `infrastructure/main.bicep` (targetScope=subscription) creates a resource group and composes modules.
- Core app module: `infrastructure/app.bicep` provisions:
  - Azure Container Apps managed environment + three apps: `frontend`, `worker`, `mcp` (Model Context Protocol service) from container images.
  - Azure Container Registry (ACR) for images, Log Analytics + Application Insights.
  - Azure OpenAI account with multiple deployments (gpt and embeddings) and RBAC.
  - Azure Storage (blob + queues + files) with Event Grid to queues; generates SAS for `tokenstore` container.
  - Azure AI Search service with system identity and RBAC to OpenAI.
  - Optional Bastion VM for private networking access and Container Apps private DNS when `usePrivateLinks && !publicContainerApps`.
- Data: `infrastructure/postgre.bicep` creates PostgreSQL Flexible Server v16 with AAD + password auth; optional private endpoint; `postgrePermissions.bicep` enables `azure.extensions`.
- Networking: `infrastructure/networks.bicep` creates VNet and subnets (containerapp, private endpoint, resource, bastion) with proper delegation and storage endpoints.
- Identity: `infrastructure/identity.bicep` creates a user-assigned managed identity (UAI) attached to all Container Apps; RBAC is assigned to ACR, Storage, OpenAI, and Search.
- Private connectivity: `infrastructure/privateEndpoint.bicep` and `containerAppPrivateDns.bicep` wire private endpoints and DNS when enabled.
- Optional edge: `infrastructure/app-gateway.bicep` is provided for an App Gateway + Private Link Service but is not invoked by `main.bicep`.

## Parameters, toggles, and conventions
- Images: `frontendImage`, `workerImage`, `mcpImage` are injected via `infrastructure/main.parameters.json`.
  - Container apps are skipped if any `*ResourceExists` flag is false: `skipContainerApps = !frontendResourceExists || !workerResourceExists || !mcpResourceExists`.
- Environment shaping:
  - `usePrivateLinks` toggles private endpoints + private DNS + stricter network ACLs.
  - `publicContainerApp` controls external ingress for ACA services.
  - `useWorkloadProfiles` selects profile `Dedicated` with larger CPU/memory; otherwise default sizing applies.
  - `deployDevelopmentQueue` creates an extra dev queue and event subscription.
- Naming & tags:
  - Short salt (`salt`) ensures uniqueness; override via `newSalt` if needed.
  - Tags include `project`, `buildId`, and `azd-env-name` and are applied across resources.
- Identity & RBAC:
  - UAI from `identity.bicep` is injected into each Container App and granted roles: ACR Pull, Storage Blob Data Owner + Queue Contributor, OpenAI (All/User access), and Azure Search roles.
  - `localPrincipalId` (optional) grants a developer user storage access for local work.

## OIDC/AAD auth for Container Apps
- `app.bicep` includes `authConfigs.bicep` but the `enableOidcAuth` variable is currently set to `false`. To enable AAD auth:
   1) Turn on `enableOidcAuth` logic in `app.bicep` (use non-empty `oidcIssuerUrl`, `oidcClientId`, `oidcClientSecret`).
  2) Ensure secrets `microsoft-provider-authentication-secret` and `token-store-sas` exist (they are already populated in `secrets`).

## Adding or changing app services
- To add another Container App:
  - Extend the `containers` object in `infrastructure/app.bicep` (image, port, scale, probes).
  - If it needs secrets/env, add to `secrets` and `credentialsEnv` (use `secretRef` for secrets). Reference common outputs like `APPLICATIONINSIGHTS_CONNECTION_STRING`, storage endpoints, and OpenAI/Search envs already defined.
  - If it must be private-only, keep `publicContainerApps=false` and rely on private DNS + internal ingress.

## Deployments and workflows
- Parameters are wired for Azure Developer CLI style substitution in `infrastructure/main.parameters.json` (e.g., `${AZURE_ENV_NAME}`, `${SERVICE_*_IMAGE_NAME}`), but there’s no `azure.yaml` here. Typical flows:
  - CI/CD or local tooling builds and pushes images to ACR, sets `*ResourceExists=true`, then deploys the Bicep via subscription-level deployment using the parameter file.
  - Use What-If before changes; validate role assignments and private DNS when `usePrivateLinks=true`.

## Key outputs to consume post-deploy
- From `main.bicep` and `app.bicep`: `MCP_ENDPOINT`, `AZURE_OPENAI_*`, `AZURE_AI_SEARCH_ENDPOINT`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `AZURE_CONTAINER_REGISTRY_ENDPOINT`, `STORAGE_ACCOUNT_NAME`/`STORAGE_CONTAINER_NAME`, `QUEUE_NAME` (or `DEV_QUEUE_NAME`), `DATABASE_HOST/NAME/SCHEMA`.

## Examples from the codebase
- Container App env vars and secrets pattern: see `credentialsEnv` and `secrets` arrays in `infrastructure/app.bicep`.
- Private endpoint pattern: see `module <service>PrivateEndpoint 'privateEndpoint.bicep'` usages for Storage, OpenAI, and Search.
- RBAC pattern: role assignment resources near the top of `app.bicep` grant the UAI access to ACR, Storage, OpenAI, and AI Search.

Notes for agents:
- Prefer updating module parameters and shared arrays over duplicating logic.
- Respect the feature flags (`usePrivateLinks`, `useWorkloadProfiles`, `publicContainerApp`) to keep environments consistent.
- When enabling auth, wire `authConfigs.bicep` via `enableOidcAuth` and verify token store SAS secret.
