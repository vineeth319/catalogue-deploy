# Create EC2 instance
resource "aws_instance" "catalogue" {
  ami                    = local.ami_id
  vpc_security_group_ids = [local.catalogue_sg_id]
  subnet_id              = local.private_subnet_id
  instance_type          = "t3.micro"
  tags = merge(
    {
      Name = "${var.project}-${var.environment}-catalogue"
    },
    local.common_tags
  )
}
# Configure it using terraform_data.catalogue
resource "terraform_data" "catalogue" {

  triggers_replace = [
    aws_instance.catalogue.id
  ]
  connection {
    type     = "ssh"
    user     = "ec2-user"
    password = "DevOps321"
    host     = aws_instance.catalogue.private_ip

    bastion_host     = local.bastion_public_ip
    bastion_user     = "ec2-user"
    bastion_password = "DevOps321"
  }

  provisioner "file" {
    source      = "bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap.sh",
      "sudo sh /tmp/bootstrap.sh catalogue ${var.environment} ${var.app_version}"

    ]
  }

}

# Stop the instance
resource "aws_ec2_instance_state" "catalogue" {
  instance_id = aws_instance.catalogue.id
  state       = "stopped"
  depends_on  = [terraform_data.catalogue]
}
# Create AMI from the instance
resource "aws_ami_from_instance" "catalogue" {
  name               = "${var.project}-${var.environment}-catalogue"
  source_instance_id = aws_instance.catalogue.id
  depends_on         = [aws_ec2_instance_state.catalogue]
  tags = merge(
    {
      Name = "${var.project}-${var.environment}-catalogue"
    },
    local.common_tags
  )

}

# Create Target Group
resource "aws_lb_target_group" "catalogue" {
  name     = "${var.project}-${var.environment}-catalogue"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = local.vpc_id

  # When an instance is removed from the target group,
  # ALB waits 60 seconds before fully removing it.
  # Existing requests can complete during this period.
  deregistration_delay = 60

  health_check {

    # Instance becomes healthy after 2 consecutive successful checks.
    healthy_threshold = 2

    # Perform health check every 10 seconds.
    interval = 10

    # Expected HTTP response code.
    # Any response between 200 and 299 is considered successful.
    matcher = "200-299"

    # URL path used for health checking.
    # ALB sends requests to:
    # http://<instance>:8080/health
    path = "/health"

    port     = 8080
    protocol = "HTTP"

    # Wait only 2 seconds for a response.
    # If no response is received within 2 seconds,
    # the health check is marked as failed.
    timeout = 2

    # Instance becomes unhealthy after 3 consecutive failures.
    unhealthy_threshold = 3
  }
}
# Create Launch Template using the AMI
resource "aws_launch_template" "catalogue" {
  name     = "${var.project}-${var.environment}-catalogue"
  image_id = aws_ami_from_instance.catalogue.id

  # If the operating system initiates a shutdown,
  # AWS will terminate the instance instead of stopping it.
  instance_initiated_shutdown_behavior = "terminate"

  instance_type          = "t3.micro"
  vpc_security_group_ids = [local.catalogue_sg_id]

  # Whenever Terraform detects a change in the launch template,
  # it creates a new version and automatically marks it as the default version.
  # Without this, you would have to manually specify
  # which version should be the default.
  update_default_version = true

  # tags for instances created by launch template through autoscaling
  tag_specifications {
    resource_type = "instance"

    tags = merge(
      {
        Name = "${var.project}-${var.environment}-catalogue"
      },
      local.common_tags
    )
  }
  # tags for volumes created by instances
  tag_specifications {
    resource_type = "volume"

    tags = merge(
      {
        Name = "${var.project}-${var.environment}-catalogue"
      },
      local.common_tags
    )
  }
  # tags for launch template
  tags = merge(
    {
      Name = "${var.project}-${var.environment}-catalogue"
    },
    local.common_tags
  )
}

# Create Auto Scaling Group using the Launch Template
# Attach ASG to Target Group
resource "aws_autoscaling_group" "catalogue" {
  name                      = "${var.project}-${var.environment}-catalogue"
  max_size                  = 10
  min_size                  = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  desired_capacity          = 1
  # Delete gracefully
  # Wait for instances to go away
  force_delete              = false
  
  launch_template {
    id      = aws_launch_template.catalogue.id
    version = "$Latest"
  }


  vpc_zone_identifier = [local.private_subnet_id]
  # Attach ASG to Target Group
  target_group_arns   = [aws_lb_target_group.catalogue.arn]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    #triggers = ["launch_template"]
    #The AWS provider now knows that Launch Template changes inherently require a refresh, so specifying the trigger is redundant and generates a warning.
  }

  dynamic "tag" {
    for_each = merge(
      {
        Name = "${var.project}-${var.environment}-catalogue"
      },
      local.common_tags
    )
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # with in 15min autoscaling should be successful
  timeouts {
    delete = "15m"
  }
}

# Create Auto Scaling Policy
resource "aws_autoscaling_policy" "catalogue" {
  autoscaling_group_name = aws_autoscaling_group.catalogue.name
  name                   = "${var.project}-${var.environment}-catalogue"
  policy_type            = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 70.0
  }
}

# Create a listener rule on the backend ALB listener
resource "aws_lb_listener_rule" "catalogue" {
   # Attach this rule to the backend ALB listener
  listener_arn = local.backend_alb_listener_arn
  priority     = 10

  action {
    type             = "forward"
     # Forward matching requests to the Catalogue target group
    target_group_arn = aws_lb_target_group.catalogue.arn
  }

  condition {
    host_header {
      # Match requests whose Host header is:
      # catalogue.backend-alb-dev.example.com
      values = ["catalogue.backend-alb-${var.environment}.${var.domain_name}"]
    }
  }
}


resource "terraform_data" "catalogue_delete" {
  triggers_replace = [
    aws_instance.catalogue.id
  ]
  depends_on = [aws_autoscaling_policy.catalogue]
  
  provisioner "local-exec" {
     command = "aws ec2 terminate-instances --instance-ids ${aws_instance.catalogue.id} --region us-east-1" 
  }
}

