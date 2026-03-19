#!/bin/bash
# Setup Azure resources for meeting sidecar service.
# Run from local machine with Azure CLI authenticated.
#
# Prerequisites:
#   az account set --subscription "<SUBSCRIPTION_ID>"

set -euo pipefail

RG="rg-ai-agent-prod"
LOCATION="australiaeast"
ACS_NAME="acs-openclaw-agent"
SPEECH_NAME="speech-openclaw-agent"
APP_CLIENT_ID="<APP_CLIENT_ID>"
APP_SP_ID="<SERVICE_PRINCIPAL_ID>"

echo "=== 1. Create ACS resource ==="
az communication create \
  --name "$ACS_NAME" \
  --resource-group "$RG" \
  --location global \
  --data-location australia \
  --tags project=ai-agent environment=poc owner=<USER_TAG>

echo ""
echo "=== 2. Get ACS connection string ==="
ACS_KEYS=$(az communication list-key --name "$ACS_NAME" --resource-group "$RG" --output json)
echo "Primary connection string:"
echo "$ACS_KEYS" | jq -r '.primaryConnectionString'
echo ""
echo "ACS endpoint:"
echo "https://${ACS_NAME}.australia.communication.azure.com"

echo ""
echo "=== 3. Create Azure AI Speech resource ==="
az cognitiveservices account create \
  --name "$SPEECH_NAME" \
  --resource-group "$RG" \
  --kind SpeechServices \
  --sku S0 \
  --location "$LOCATION" \
  --tags project=ai-agent environment=poc owner=<USER_TAG>

echo ""
echo "=== 4. Get Speech key ==="
SPEECH_KEY=$(az cognitiveservices account keys list \
  --name "$SPEECH_NAME" \
  --resource-group "$RG" \
  --query "key1" --output tsv)
echo "Speech key: $SPEECH_KEY"

echo ""
echo "=== 5. Add Graph permissions ==="
GRAPH_SP_ID=$(az rest --method GET \
  --url 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId%20eq%20%2700000003-0000-0000-c000-000000000000%27' \
  --query "value[0].id" --output tsv)

# Calls.JoinGroupCall.All
CALLS_JOIN_ID="f6b49018-60ab-4f81-83bd-22caeabfed2d"
# OnlineMeetingTranscript.Read.All
TRANSCRIPT_READ_ID="a4a80d8d-d283-4bd8-8504-555ec3870630"

echo "Adding Calls.JoinGroupCall.All..."
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${APP_SP_ID}/appRoleAssignments" \
  --body "{\"principalId\":\"${APP_SP_ID}\",\"resourceId\":\"${GRAPH_SP_ID}\",\"appRoleId\":\"${CALLS_JOIN_ID}\"}" \
  2>/dev/null || echo "  (may already exist)"

echo "Adding OnlineMeetingTranscript.Read.All..."
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${APP_SP_ID}/appRoleAssignments" \
  --body "{\"principalId\":\"${APP_SP_ID}\",\"resourceId\":\"${GRAPH_SP_ID}\",\"appRoleId\":\"${TRANSCRIPT_READ_ID}\"}" \
  2>/dev/null || echo "  (may already exist)"

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Run setup-teams-interop.ps1 (the user — Teams Admin PowerShell)"
echo "  2. Add these to /home/ai-agent/workspace/.env on the VM:"
echo "     ACS_CONNECTION_STRING=<primary connection string above>"
echo "     ACS_ENDPOINT=https://${ACS_NAME}.australia.communication.azure.com"
echo "     SPEECH_KEY=$SPEECH_KEY"
echo "     SPEECH_REGION=$LOCATION"
echo "  3. Run the verification test: npm run dev (from meeting-service/)"