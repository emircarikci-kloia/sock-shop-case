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
    bucket         = "kloia-case-state-emir-unique" # 1.adımda yarattığım bucket ismi
    key            = "prod/terraform.tfstate"       #dosyanın S3 içindeki yolu
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

  public_subnet_tags = { # dışarı açılacaklar public
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = { # internal olanları private subnet
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.21"

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
      max_size     = 10
      desired_size = 5

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

resource "aws_security_group_rule" "vault_webhook" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  security_group_id = module.eks.node_security_group_id # node id
  source_security_group_id = module.eks.cluster_security_group_id # cluster id
  description       = "Control Plane vault injector erisimine izin"
}

module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                        = "cluster-autoscaler-role"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_name]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

output "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler IAM Role ARN"
  value       = module.cluster_autoscaler_irsa.iam_role_arn
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions_role" {
  name = "kloia-sock-shop-actions-role" # rol ismi 

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity" # bu rol oidc ile alınabilir 
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn # Sadece yukarıda tanımladığımız GitHub sağlayıcısı bu rolü alabilir
        }
        Condition = {
          StringLike = {
            # sadece reponun main branch'ine izin veriyoruz
            "token.actions.githubusercontent.com:sub" : "repo:emircarikci-kloia/sock-shop-case:ref:refs/heads/main"
          }
          StringEquals = {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_power_user" { # ecr için role yetki verme
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

output "github_role_arn" {
  description = "add to YAML adress"
  value       = aws_iam_role.github_actions_role.arn
}