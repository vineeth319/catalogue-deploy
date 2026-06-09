terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>6.0"
    }
  }
  backend "s3" {
    bucket       = "devops-practice-vineeth.online"
    key          = "roboshop-infra-catalogue.tfstate"
    use_lockfile = true
    encrypt      = true
    region       = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}