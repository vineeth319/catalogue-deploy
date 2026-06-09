locals {
  vpc_id                   = data.aws_ssm_parameter.vpc_id.value
  catalogue_sg_id          = data.aws_ssm_parameter.catalogue_sg_id.value
  ami_id                   = data.aws_ami.joindevops.id
  private_subnet_id        = split(",", data.aws_ssm_parameter.private_subnet_ids.value)[0]
  bastion_public_ip        = data.aws_ssm_parameter.bastion_public_ip.value
  backend_alb_listener_arn = data.aws_ssm_parameter.backend_alb_listener_arn.value
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Terraform   = "true"
  }
}
