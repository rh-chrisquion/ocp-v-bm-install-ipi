# Optional SSM-only bastion host for reaching a private cluster's API and
# console. Not part of the ROSA HCP module itself -- this is plain AWS
# infrastructure, independent of whether VPC discovery or explicit subnet
# IDs are in use, so it works the same way regardless of enable_vpc_discovery.
#
# No SSH key pair and no inbound security group rules are used. Access is
# exclusively through AWS Systems Manager Session Manager (IAM- and
# CloudTrail-audited), using port forwarding to reach the cluster's private
# API/console endpoints from a local machine. See "Connecting to a private
# cluster via the bastion host" in README.md for client-side steps.

data "aws_subnet" "bastion_vpc_lookup" {
  count = var.create_bastion ? 1 : 0

  id = local.effective_private_subnet_ids[0]
}

data "aws_ami" "al2023" {
  count       = var.create_bastion && var.bastion_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_policy_document" "bastion_assume_role" {
  count = var.create_bastion ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  count              = var.create_bastion ? 1 : 0
  name               = "${var.cluster_name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role[0].json
  tags               = local.base_tags
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count      = var.create_bastion ? 1 : 0
  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.create_bastion ? 1 : 0
  name  = "${var.cluster_name}-bastion"
  role  = aws_iam_role.bastion[0].name
}

resource "aws_security_group" "bastion" {
  count       = var.create_bastion ? 1 : 0
  name        = "${var.cluster_name}-bastion"
  description = "SSM-only bastion for reaching the private cluster API/console. No inbound rules -- SSM connects outbound from the instance."
  vpc_id      = data.aws_subnet.bastion_vpc_lookup[0].vpc_id
  tags        = local.base_tags

  egress {
    description = "HTTPS to SSM endpoints and the private cluster API/console"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  count = var.create_bastion ? 1 : 0

  ami                    = coalesce(var.bastion_ami_id, try(data.aws_ami.al2023[0].id, null))
  instance_type          = var.bastion_instance_type
  subnet_id              = local.effective_private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bastion[0].id]
  iam_instance_profile   = aws_iam_instance_profile.bastion[0].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = merge(local.base_tags, {
    Name = "${var.cluster_name}-bastion"
  })
}
