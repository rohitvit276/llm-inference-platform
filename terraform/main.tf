data "aws_availability_zones" "available" {
  state = "available"
}

# Public-subnet-only VPC: avoids NAT gateway cost (~$32/mo) entirely.
# Fine for a lab; a production writeup should call out private subnets + NAT.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.26"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    metrics-server = {}
  }

  eks_managed_node_groups = {
    spot = {
      instance_types = var.node_instance_types
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Nodes in public subnets need public IPs to reach the internet (no NAT).
      subnet_ids = module.vpc.public_subnets
    }
  }
}
