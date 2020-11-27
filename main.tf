#------------------------------------------------------------------------------
# S3 BUCKET - For access logs
#------------------------------------------------------------------------------
resource "aws_s3_bucket" "logs" {
  bucket = "${var.name_prefix}-lb-logs"
  acl    = "log-delivery-write"
  tags = {
    Name = "${var.name_prefix}-lb-logs"
  }
}

#------------------------------------------------------------------------------
# APPLICATION LOAD BALANCER
#------------------------------------------------------------------------------
resource "aws_lb" "lb" {
  name                             = "${var.name_prefix}-lb"
  internal                         = var.internal
  load_balancer_type               = "application"
  drop_invalid_header_fields       = var.drop_invalid_header_fields
  subnets                          = var.internal ? var.private_subnets : var.public_subnets
  idle_timeout                     = var.idle_timeout
  enable_deletion_protection       = var.enable_deletion_protection
  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_http2                     = var.enable_http2
  ip_address_type                  = var.ip_address_type
  security_groups = compact(
    concat(var.security_groups, [aws_security_group.lb_access_sg.id]),
  )

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    enabled = true
  }

  tags = {
    Name = "${var.name_prefix}-lb"
  }
}

#------------------------------------------------------------------------------
# ACCESS CONTROL TO APPLICATION LOAD BALANCER
#------------------------------------------------------------------------------
resource "aws_security_group" "lb_access_sg" {
  name        = "${var.name_prefix}-lb-access-sg"
  description = "Controls access to the Load Balancer"
  vpc_id      = var.vpc_id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.name_prefix}-lb-access-sg"
  }
}

resource "aws_security_group_rule" "ingress_through_http" {
  for_each          = var.http_ports
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = each.value.listener_port
  to_port           = each.value.listener_port
  protocol          = "tcp"
  cidr_blocks       = var.http_ingress_cidr_blocks
  prefix_list_ids   = var.http_ingress_prefix_list_ids
}

resource "aws_security_group_rule" "ingress_through_https" {
  for_each          = var.https_ports
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = each.value.listener_port
  to_port           = each.value.listener_port
  protocol          = "tcp"
  cidr_blocks       = var.https_ingress_cidr_blocks
  prefix_list_ids   = var.https_ingress_prefix_list_ids
}

#------------------------------------------------------------------------------
# AWS LOAD BALANCER - Target Groups
#------------------------------------------------------------------------------
resource "aws_lb_target_group" "lb_http_tgs" {
  for_each                      = var.http_ports
  name                          = "${var.name_prefix}-http-${each.value.target_group_port}"
  port                          = each.value.target_group_port
  protocol                      = "HTTP"
  vpc_id                        = var.vpc_id
  deregistration_delay          = var.deregistration_delay
  slow_start                    = var.slow_start
  load_balancing_algorithm_type = var.load_balancing_algorithm_type
  dynamic "stickiness" {
    for_each = var.stickiness == null ? [] : [var.stickiness]
    content {
      type            = stickiness.value.type
      cookie_duration = stickiness.value.cookie_duration
      enabled         = stickiness.value.enabled
    }
  }
  health_check {
    enabled             = var.target_group_health_check_enabled
    interval            = var.target_group_health_check_interval
    path                = var.target_group_health_check_path
    protocol            = "HTTP"
    timeout             = var.target_group_health_check_timeout
    healthy_threshold   = var.target_group_health_check_healthy_threshold
    unhealthy_threshold = var.target_group_health_check_unhealthy_threshold
    matcher             = var.target_group_health_check_matcher
  }
  target_type = "ip"
  tags = {
    Name = "${var.name_prefix}-http-${each.value.target_group_port}"
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [aws_lb.lb]
}

resource "aws_lb_target_group" "lb_https_tgs" {
  for_each                      = var.https_ports
  name                          = "${var.name_prefix}-https-${each.value.target_group_port}"
  port                          = each.value.target_group_port
  protocol                      = "HTTPS"
  vpc_id                        = var.vpc_id
  deregistration_delay          = var.deregistration_delay
  slow_start                    = var.slow_start
  load_balancing_algorithm_type = var.load_balancing_algorithm_type
  dynamic "stickiness" {
    for_each = var.stickiness == null ? [] : [var.stickiness]
    content {
      type            = stickiness.value.type
      cookie_duration = stickiness.value.cookie_duration
      enabled         = stickiness.value.enabled
    }
  }
  health_check {
    enabled             = var.target_group_health_check_enabled
    interval            = var.target_group_health_check_interval
    path                = var.target_group_health_check_path
    protocol            = "HTTPS"
    timeout             = var.target_group_health_check_timeout
    healthy_threshold   = var.target_group_health_check_healthy_threshold
    unhealthy_threshold = var.target_group_health_check_unhealthy_threshold
    matcher             = var.target_group_health_check_matcher
  }
  target_type = "ip"
  tags = {
    Name = "${var.name_prefix}-https-${each.value.target_group_port}"
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [aws_lb.lb]
}

#------------------------------------------------------------------------------
# AWS LOAD BALANCER - Listeners
#------------------------------------------------------------------------------
resource "aws_lb_listener" "lb_http_listeners" {
  for_each          = var.http_ports
  load_balancer_arn = aws_lb.lb.arn
  port              = each.value.listener_port
  protocol          = aws_lb_target_group.lb_http_tgs[each.key].protocol
  default_action {
    target_group_arn = aws_lb_target_group.lb_http_tgs[each.key].arn
    type             = "forward"
  }
}

resource "aws_lb_listener" "lb_https_listeners" {
  for_each          = var.https_ports
  load_balancer_arn = aws_lb.lb.arn
  port              = each.value.listener_port
  protocol          = aws_lb_target_group.lb_https_tgs[each.key].protocol
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.default_certificate_arn
  default_action {
    target_group_arn = aws_lb_target_group.lb_https_tgs[each.key].arn
    type             = "forward"
  }
}

# TODO - Think a way to add multiple additional certificates to multiple listeners.
# resource "aws_lb_listener_certificate" "additional_certificates_for_https_listeners" {
#   for_each        = toset(var.additional_certificates_arn_for_https_listeners)
#   listener_arn    = aws_lb_listener.lb_https_listeners.arn
#   certificate_arn = each.key
# }
