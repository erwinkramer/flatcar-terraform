terraform {
  required_version = ">= 0.13"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>2.0"
    }
    ct = {
      source  = "poseidon/ct"
      version = "0.11.0"
    }
    template = {
      source  = "hashicorp/template"
      version = "~> 2.2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "${var.cluster_name}-rg"
  location = var.resource_group_location
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.cluster_name}-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_public_ip" "pip" {
  for_each            = toset(var.machines)
  name                = "${var.cluster_name}-${each.key}-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Dynamic"
}

resource "azurerm_network_security_group" "nsg" {
  name                = "${var.cluster_name}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-DNS"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "main" {
  for_each            = toset(var.machines)
  name                = "${var.cluster_name}-${each.key}-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "example" {
  for_each                  = toset(var.machines)
  network_interface_id      = azurerm_network_interface.main[each.key].id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "null_resource" "reboot-when-ignition-changes" {
  for_each = toset(var.machines)
  triggers = {
    ignition_config    = azurerm_linux_virtual_machine.machine[each.key].user_data
    reprovision_helper = data.template_file.reprovision[each.key].rendered
  }
  depends_on = [azurerm_linux_virtual_machine.machine]
  provisioner "local-exec" {
    command = data.template_file.reprovision[each.key].rendered
  }
}

data "template_file" "reprovision" {
  for_each = toset(var.machines)
  template = file("${path.module}/reprovision-helper")

  vars = {
    KEEPPATHS = "'/etc/ssh/ssh_host_.*' /mydata /var/log"
    RGROUP    = azurerm_resource_group.main.name
    NAME      = azurerm_linux_virtual_machine.machine[each.key].name
    PUBLICIP  = azurerm_linux_virtual_machine.machine[each.key].public_ip_address
    MODE      = var.mode
    PORT      = var.ssh_port
    EXPECTED  = azurerm_linux_virtual_machine.machine[each.key].user_data
  }
}

resource "azurerm_linux_virtual_machine" "machine" {
  for_each            = toset(var.machines)
  name                = "${var.cluster_name}-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.server_type
  admin_username      = "core"

  user_data = base64encode(data.ct_config.machine-ignitions[each.key].rendered)
  network_interface_ids = [
    azurerm_network_interface.main[each.key].id,
  ]

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_keys.0
  }

  source_image_reference {
    publisher = "kinvolk"
    offer     = "flatcar-container-linux"
    sku       = "stable"
    version   = var.flatcar_stable_version
  }

  plan {
    name      = "stable"
    product   = "flatcar-container-linux"
    publisher = "kinvolk"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }
}

data "ct_config" "machine-ignitions" {
  for_each = toset(var.machines)
  content  = data.template_file.machine-configs[each.key].rendered
  strict   = true
}

data "template_file" "machine-configs" {
  for_each = toset(var.machines)
  template = file("${path.module}/cl/machine-${each.key}.yaml.tmpl")

  vars = {
    ssh_keys = jsonencode(var.ssh_keys)
    name     = each.key
    port     = var.ssh_port
  }
}
