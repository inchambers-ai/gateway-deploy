// inchambers-gateway — Azure VM deployment (single B2s running docker-compose).
//
// Cheapest Azure path — one ~$30/mo VM runs the entire gateway (Caddy +
// relay + LiteLLM + admin-ui + Postgres) via docker-compose. Cloud-init
// on first boot installs Docker Engine, pulls the compose bundle from the
// public deploy repo, renders .env with the parameters you pass here,
// and starts the stack.
//
// Why not Container Apps?
//   * 4 always-on Container Apps + managed Postgres + Redis = ~$110/mo.
//   * One B2s VM with docker-compose = ~$30/mo for identical throughput
//     at a 5-50 seat firm.
//   * Container Apps shines when traffic is bursty and scale-to-zero
//     beats paying for an always-on VM — that's not this workload.
//
// Usage:
//   az group create -n rg-ic-gateway -l eastus
//   az deployment group create \
//     -g rg-ic-gateway \
//     -f main.bicep \
//     -p name=acme-firm orgId=<uuid> adminEmail=admin@firm.com \
//        sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
//        openRouterApiKey=<secret> \
//        gatewayDomain=gateway.firm.com

targetScope = 'resourceGroup'

@description('Short name prefix for all resources (lowercase, 3-20 chars).')
@minLength(3)
@maxLength(20)
param name string

@description('Azure region.')
param location string = resourceGroup().location

@description('VM size. B2s (2 vCPU, 4 GB, ~$30/mo) is the default; B2ms (2 vCPU, 8 GB) for heavier load; B1s (1 vCPU, 1 GB, ~$8/mo) for tiny firms.')
@allowed([
  'Standard_B1s'
  'Standard_B2s'
  'Standard_B2ms'
  'Standard_B4ms'
])
param vmSize string = 'Standard_B2s'

@description('inchambers.ai org UUID this gateway serves.')
param orgId string

@description('Public hostname the gateway will be reachable at. Must point to the VM\'s public IP for Let\'s Encrypt certs. Leave empty to use the VM\'s Azure-assigned DNS name.')
param gatewayDomain string = ''

@description('Email for Let\'s Encrypt cert registration.')
param adminEmail string

@description('SSH public key (paste contents of ~/.ssh/id_rsa.pub or id_ed25519.pub).')
param sshPublicKey string

@secure()
@description('Base64-encoded 32-byte master key for encrypting subscription cookies at rest. Generate: openssl rand -base64 32')
param gatewayMasterKey string

@secure()
@description('LiteLLM admin key (random secret). Generate: "sk-$(openssl rand -hex 24)"')
param litellmMasterKey string

@secure()
@description('Postgres password for the bundled DB. Must stay STABLE across redeploys (the DB volume persists), so supply your own value rather than regenerating. Generate once: openssl rand -hex 16. Replaces the old uniqueString() derivation, which was deterministic and not a secret.')
param pgPassword string

@secure()
@description('Optional OpenRouter API key. Leave empty to configure later via the admin UI.')
param openRouterApiKey string = ''

@description('Optional Azure AI Foundry resource URL.')
param foundryUrl string = ''

@secure()
@description('Optional Azure AI Foundry API key.')
param foundryKey string = ''

@description('Browser origin allowed to call the gateway.')
param allowedOrigin string = 'https://app.inchambers.ai'

@description('JWKS URL for validating inchambers.ai JWTs.')
param jwksUrl string = 'https://app.inchambers.ai/.well-known/jwks.json'

@description('Container registry + tag. Default pulls public images from GHCR; override for BYO-registry deployments.')
param imageRegistry string = 'ghcr.io/inchambers-ai'

@description('Gateway image tag. Pin to a specific version for production; `latest` tracks the stable release.')
param imageTag string = 'latest'

@description('Source CIDR/prefix allowed to reach SSH (port 22). Default "*" = anywhere (backwards-compatible) — set to your admin IP/range for production, e.g. "203.0.113.4/32".')
param sshSourcePrefix string = '*'

// ────────────────────────────────────────────────────────────────────────────
// Networking — public IP + NSG (22/80/443) + VNet + NIC
// ────────────────────────────────────────────────────────────────────────────
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${name}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower(name)
    }
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${name}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSsh'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sshSourcePrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'AllowHttp'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'AllowHttps'
        properties: {
          priority: 1020
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.50.0.0/16' ] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.50.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/default' }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Cloud-init — runs on first boot: installs Docker, fetches compose +
// Caddyfiles from the public deploy repo, renders .env with the ARM
// parameters, and starts the stack. Secrets live in Azure's customData
// channel and never appear in ARM get responses.
// ────────────────────────────────────────────────────────────────────────────
var effectiveDomain = empty(gatewayDomain) ? pip.properties.dnsSettings.fqdn : gatewayDomain

var cloudInit = '''#cloud-config
package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
runcmd:
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker azureuser
  - mkdir -p /opt/inchambers-gateway/caddy
  - curl -fsSL https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/docker-compose.yaml -o /opt/inchambers-gateway/docker-compose.yaml
  - curl -fsSL https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/caddy/Caddyfile -o /opt/inchambers-gateway/caddy/Caddyfile
  - curl -fsSL https://raw.githubusercontent.com/inchambers-ai/gateway-deploy/main/caddy/Caddyfile.notls -o /opt/inchambers-gateway/caddy/Caddyfile.notls
  - |
    cat > /opt/inchambers-gateway/.env <<ENV
    GATEWAY_ORG_ID=__ORG_ID__
    GATEWAY_DOMAIN=__GATEWAY_DOMAIN__
    CADDY_TLS_MODE=auto
    CADDY_ACME_EMAIL=__ADMIN_EMAIL__
    ALLOWED_ORIGIN=__ALLOWED_ORIGIN__
    JWKS_URL=__JWKS_URL__
    GATEWAY_MASTER_KEY=__GATEWAY_MASTER_KEY__
    LITELLM_MASTER_KEY=__LITELLM_MASTER_KEY__
    OPENROUTER_API_KEY=__OPENROUTER_API_KEY__
    AZURE_FOUNDRY_URL=__AZURE_FOUNDRY_URL__
    AZURE_FOUNDRY_KEY=__AZURE_FOUNDRY_KEY__
    PG_PASSWORD=__PG_PASSWORD__
    REGISTRY=__IMAGE_REGISTRY__
    IMAGE_TAG=__IMAGE_TAG__
    ENV
  - chmod 600 /opt/inchambers-gateway/.env
  - chown -R azureuser:azureuser /opt/inchambers-gateway
  - cd /opt/inchambers-gateway && docker compose pull && docker compose up -d
'''

// Substitute parameters into the cloud-init template.
var renderedCloudInit = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
  cloudInit,
  '__ORG_ID__', orgId),
  '__GATEWAY_DOMAIN__', effectiveDomain),
  '__ADMIN_EMAIL__', adminEmail),
  '__ALLOWED_ORIGIN__', allowedOrigin),
  '__JWKS_URL__', jwksUrl),
  '__GATEWAY_MASTER_KEY__', gatewayMasterKey),
  '__LITELLM_MASTER_KEY__', litellmMasterKey),
  '__OPENROUTER_API_KEY__', openRouterApiKey),
  '__AZURE_FOUNDRY_URL__', foundryUrl),
  '__AZURE_FOUNDRY_KEY__', foundryKey),
  '__PG_PASSWORD__', pgPassword),
  '__IMAGE_REGISTRY__', imageRegistry),
  '__IMAGE_TAG__', imageTag)

// ────────────────────────────────────────────────────────────────────────────
// The VM itself — Ubuntu 24.04 LTS, default 32 GB SSD.
// ────────────────────────────────────────────────────────────────────────────
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: '${name}-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        diskSizeGB: 32
      }
    }
    osProfile: {
      computerName: replace(name, '-', '')
      adminUsername: 'azureuser'
      customData: base64(renderedCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/azureuser/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Outputs
// ────────────────────────────────────────────────────────────────────────────
output gatewayUrl string = 'https://${effectiveDomain}'
output publicIp string = pip.properties.ipAddress
output sshCommand string = 'ssh azureuser@${pip.properties.ipAddress}'
output dnsHint string = empty(gatewayDomain)
  ? 'Using Azure-assigned DNS: ${pip.properties.dnsSettings.fqdn}. First curl after boot may take ~2 min for Docker pull + cold start.'
  : 'Point DNS: ${gatewayDomain} → ${pip.properties.ipAddress}. Let\'s Encrypt provisions the cert on first HTTPS request.'
