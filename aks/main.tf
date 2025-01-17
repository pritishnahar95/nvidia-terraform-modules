# SPDX-FileCopyrightText: Copyright (c) 2022-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

data "azurerm_resource_group" "existing" {
  count = var.existing_resource_group_name == null ? 0 : 1
  name = var.existing_resource_group_name
}

resource "azurerm_resource_group" "holoscan" {
  count = var.existing_resource_group_name == null ? 1 : 0
  name     = "${var.cluster_name}-rg"
  location = var.location
  tags = {
    group      = "Holoscan"
    managed_by = "Terraform"
  }
}

resource "azurerm_kubernetes_cluster" "holoscan" {
  name                = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  resource_group_name = var.existing_resource_group_name == null ? azurerm_resource_group.holoscan[0].name : data.azurerm_resource_group.existing[0].name
  location            = var.existing_resource_group_name == null ? azurerm_resource_group.holoscan[0].location : data.azurerm_resource_group.existing[0].location
  dns_prefix          = var.cluster_name

  default_node_pool {
    name                = "holoscancpu"
    node_count          = var.cpu_node_pool_count
    enable_auto_scaling = true
    min_count           = var.cpu_node_pool_min_count
    max_count           = var.cpu_node_pool_max_count
    vm_size             = var.cpu_machine_type
    os_disk_size_gb     = var.cpu_node_pool_disk_size
  }

  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    group      = "Holoscan"
    managed_by = "Terraform"
  }

  // As the cluster is being created, have the az CLI update the users kubeconfig file
  provisioner "local-exec" {
    command = "az aks get-credentials --resource-group ${var.existing_resource_group_name == null ? azurerm_resource_group.holoscan[0].name : data.azurerm_resource_group.existing[0].name} --name ${var.cluster_name} --overwrite-existing"
  }

  provisioner "local-exec" {
    command = "kubelogin convert-kubeconfig -l azurecli"
  }
}

data "azurerm_kubernetes_cluster" "holoscancluster" {
  name                = azurerm_kubernetes_cluster.holoscan.name
  resource_group_name = var.existing_resource_group_name == null ? azurerm_resource_group.holoscan[0].name : data.azurerm_resource_group.existing[0].name
  depends_on          = [azurerm_kubernetes_cluster.holoscan]
}

resource "azurerm_kubernetes_cluster_node_pool" "holoscan" {
  depends_on            = [azurerm_kubernetes_cluster.holoscan]
  name                  = "holoscangpu1"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.holoscan.id
  node_count            = var.gpu_node_pool_count
  enable_auto_scaling   = true
  min_count             = var.gpu_node_pool_min_count
  max_count             = var.gpu_node_pool_max_count
  vm_size               = var.gpu_machine_type
  os_disk_size_gb       = var.gpu_node_pool_disk_size
  tags = {
    group      = "Holoscan"
    managed_by = "Terraform"
  }
  // Add NVIDIA NGC Helm Repo to local helm repo via local-exec command
  provisioner "local-exec" {
    command = "helm repo add nvidia https://helm.ngc.nvidia.com/nvidia"
  }
  // install the GPU operator on successful creation of the node pool via local-exec command.
  // This solves any errors attempting to use the helm provider on a cluster that is not yet created
  // and allows for configuration of the cluster in a single provisioning step.
  // Run "helm upgrade --install" for idempotency
  provisioner "local-exec" {
    command = "helm upgrade --install  gpu-operator --version ${var.gpu_operator_version} --create-namespace --namespace gpu-operator nvidia/gpu-operator --set toolkit.enabled=true --set operator.cleanupCRD=true --set driver.enabled=false"
  }
}
