terraform {
  required_providers {
    aci = {
      source = "CiscoDevNet/aci"
      version = "2.13.2"
    }
  }
}

provider "aci" {
    username = "admin"
    password = "!v3G@!4@Y"
    url      = "https://sandboxapicdc.cisco.com"
    insecure = true
}


resource "aci_tenant" "test_tenant" {
  name        = "tf_test_rel_tenant"
  description = "This tenant is created by terraform"
}

