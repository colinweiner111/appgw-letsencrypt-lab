// backend.bicep
// Backend VMs running NGINX for Application Gateway load balancing
//
// Design decisions:
// - No public IPs on VMs (private only, access via Bastion)
// - cloud-init installs NGINX with a unique page per VM (shows LB in action)
// - 2 VMs for demonstrating round-robin load balancing

@description('Azure region')
param location string

@description('Subnet ID for backend VMs')
param subnetId string

@description('Number of backend VMs to deploy')
@minValue(1)
@maxValue(4)
param vmCount int = 2

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Admin username for the VMs')
param adminUsername string = 'azureadmin'

@description('SSH public key for authentication')
@secure()
param sshPublicKey string

@description('Name prefix for VM resources')
param vmNamePrefix string = 'vm-backend'

@description('Tags to apply to resources')
param tags object = {}

// ─── Network Interfaces (no public IP) ──────────────────────────

resource nics 'Microsoft.Network/networkInterfaces@2023-11-01' = [
  for i in range(0, vmCount): {
    name: '${vmNamePrefix}-${i + 1}-nic'
    location: location
    tags: tags
    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig1'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: subnetId
            }
          }
        }
      ]
    }
  }
]

// ─── Virtual Machines ───────────────────────────────────────────

resource vms 'Microsoft.Compute/virtualMachines@2024-03-01' = [
  for i in range(0, vmCount): {
    name: '${vmNamePrefix}-${i + 1}'
    location: location
    tags: tags
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      osProfile: {
        computerName: '${vmNamePrefix}-${i + 1}'
        adminUsername: adminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
        // cloud-init: install NGINX with unique page per VM
        customData: base64('''#!/bin/bash
apt-get update -y
apt-get install -y nginx
echo "<html><body><h1>Backend VM ${i + 1}</h1><p>Hostname: $(hostname)</p><p>Private IP: $(hostname -I | awk '{print $1}')</p></body></html>" > /var/www/html/index.html
systemctl enable nginx
systemctl start nginx
''')
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nics[i].id
          }
        ]
      }
    }
  }
]

// ─── Outputs ────────────────────────────────────────────────────

@description('Private IP addresses of backend VMs')
output backendPrivateIps array = [
  for i in range(0, vmCount): nics[i].properties.ipConfigurations[0].properties.privateIPAddress
]

@description('NIC resource IDs')
output nicIds array = [for i in range(0, vmCount): nics[i].id]
