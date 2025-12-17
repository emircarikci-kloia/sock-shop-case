terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.9"
    }
  }

  backend "s3" {
    bucket         = "kloia-case-state-emir-unique" # 1. Adımda yarattığın bucket ismi
    key            = "prod/terraform.tfstate"       # Dosyanın S3 içindeki yolu
    region         = "eu-central-1"
    encrypt        = true
  }
}

provider "aws" {
  region = "eu-central-1" 
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "5.5.1"

  name = "sock-shop-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true

  single_nat_gateway = true 
  one_nat_gateway_per_az = false

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "sock-shop-cluster"
  cluster_version = "1.32" 
  
  cluster_endpoint_public_access = true 

  vpc_id = module.vpc.vpc_id

  # privateları kullan
  subnet_ids = module.vpc.private_subnets

  # nodelar
  eks_managed_node_groups = {
    green = {
      min_size     = 1
      max_size     = 4
      desired_size = 4

      instance_types = ["t3.medium"] # kucuk olsun
      capacity_type  = "SPOT"
    }
  }

  enable_irsa = true
}

resource "aws_ecr_repository" "microservices" {
  # döngü ile 11 tane
  for_each = toset([
    "adservice",
    "cartservice",
    "checkoutservice",
    "currencyservice",
    "emailservice",
    "frontend",
    "loadgenerator",
    "paymentservice",
    "productcatalogservice",
    "recommendationservice",
    "shippingservice"
  ])

  # isimlendirme
  name = "sock-shop/${each.key}" 
  
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

/*resource "helm_release" "monitoring" {
  name       = "prometheus-stack"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  create_namespace = true

  # Cluster kurulmadan Helm çalışmasın diye:
  depends_on = [module.eks]
}*/
