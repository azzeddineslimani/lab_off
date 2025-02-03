# Configure Azure provider
provider "azurerm" {
  features {}
}

# Configure AWS provider
provider "aws" {
  region = "us-west-2"
}

# Azure Resource Group
resource "azurerm_resource_group" "bgp_lab" {
  name     = "bgp-lab-rg"
  location = "eastus"
}

# Azure Virtual Network
resource "azurerm_virtual_network" "azure_vnet" {
  name                = "azure-vnet"
  address_space       = ["10.1.0.0/16"]
  location           = azurerm_resource_group.bgp_lab.location
  resource_group_name = azurerm_resource_group.bgp_lab.name
}

# Azure Subnet
resource "azurerm_subnet" "azure_subnet" {
  name                 = "azure-subnet"
  resource_group_name  = azurerm_resource_group.bgp_lab.name
  virtual_network_name = azurerm_virtual_network.azure_vnet.name
  address_prefixes     = ["10.1.1.0/24"]
}

# AWS VPC
resource "aws_vpc" "aws_vpc" {
  cidr_block           = "10.2.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "aws-vpc"
  }
}

# AWS Subnet
resource "aws_subnet" "aws_subnet" {
  vpc_id     = aws_vpc.aws_vpc.id
  cidr_block = "10.2.1.0/24"

  tags = {
    Name = "aws-subnet"
  }
}

# Azure AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-cluster"
  location           = azurerm_resource_group.bgp_lab.location
  resource_group_name = azurerm_resource_group.bgp_lab.name
  dns_prefix         = "aks-bgp-lab"

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_D2s_v3"
    vnet_subnet_id = azurerm_subnet.azure_subnet.id
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "cilium"
  }

  identity {
    type = "SystemAssigned"
  }
}

# AWS EKS Cluster
resource "aws_eks_cluster" "eks" {
  name     = "eks-cluster"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = [aws_subnet.aws_subnet.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# AWS IAM Role for EKS
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# Cilium configuration for AKS
resource "kubernetes_namespace" "cilium_aks" {
  provider = kubernetes.aks
  metadata {
    name = "cilium"
  }
}

# Cilium Helm release for AKS
resource "helm_release" "cilium_aks" {
  provider   = helm.aks
  name       = "cilium"
  namespace  = kubernetes_namespace.cilium_aks.metadata[0].name
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.14.0"

  set {
    name  = "bgp.enabled"
    value = "true"
  }

  set {
    name  = "bgp.announce.loadbalancer"
    value = "true"
  }
}

# Cilium configuration for EKS
resource "kubernetes_namespace" "cilium_eks" {
  provider = kubernetes.eks
  metadata {
    name = "cilium"
  }
}

# Cilium Helm release for EKS
resource "helm_release" "cilium_eks" {
  provider   = helm.eks
  name       = "cilium"
  namespace  = kubernetes_namespace.cilium_eks.metadata[0].name
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.14.0"

  set {
    name  = "bgp.enabled"
    value = "true"
  }

  set {
    name  = "bgp.announce.loadbalancer"
    value = "true"
  }
}

# BGP configuration for Cilium in AKS
resource "kubernetes_config_map" "bgp_config_aks" {
  provider = kubernetes.aks
  metadata {
    name      = "bgp-config"
    namespace = "cilium"
  }

  data = {
    "config.yaml" = <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumBGPPeeringPolicy
metadata:
  name: bgp-peering-policy
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  virtualRouters:
    - localASN: 65001
      exportPodCIDR: true
      neighbors:
        - peerASN: 65002
          peerAddress: ${aws_eks_cluster.eks.endpoint}
EOF
  }
}

# BGP configuration for Cilium in EKS
resource "kubernetes_config_map" "bgp_config_eks" {
  provider = kubernetes.eks
  metadata {
    name      = "bgp-config"
    namespace = "cilium"
  }

  data = {
    "config.yaml" = <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumBGPPeeringPolicy
metadata:
  name: bgp-peering-policy
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  virtualRouters:
    - localASN: 65002
      exportPodCIDR: true
      neighbors:
        - peerASN: 65001
          peerAddress: ${azurerm_kubernetes_cluster.aks.fqdn}
EOF
  }
}

# Test application deployment
resource "kubernetes_deployment" "test_app_aks" {
  provider = kubernetes.aks
  metadata {
    name = "test-app"
    labels = {
      app = "test"
    }
  }

  spec {
    replicas = 2
    selector {
      match_labels = {
        app = "test"
      }
    }
    template {
      metadata {
        labels = {
          app = "test"
        }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginx:latest"
          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "test_app_aks" {
  provider = kubernetes.aks
  metadata {
    name = "test-app"
  }
  spec {
    selector = {
      app = "test"
    }
    port {
      port        = 80
      target_port = 80
    }
    type = "LoadBalancer"
  }
}

# Output important information
output "aks_cluster_endpoint" {
  value = azurerm_kubernetes_cluster.aks.kube_config.0.host
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "test_app_service_ip" {
  value = kubernetes_service.test_app_aks.status.0.load_balancer.0.ingress.0.ip
}
