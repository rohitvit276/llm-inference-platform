variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "llm-platform"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "node_instance_types" {
  description = "Instance types for the spot node group (CPU inference)"
  type        = list(string)
  default     = ["t3.large", "t3a.large", "m5.large", "m5a.large"]
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Max node count (cluster-autoscaler / KEDA headroom)"
  type        = number
  default     = 3
}

variable "budget_limit_usd" {
  description = "Monthly AWS budget alarm threshold in USD"
  type        = string
  default     = "15"
}

variable "budget_email" {
  description = "Email address for budget alerts"
  type        = string
}
