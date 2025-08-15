locals {
  name            = coalesce(module.this.name, var.name, "cognito-hooks")
  enabled         = module.this.enabled
  aws_account_id  = one(data.aws_caller_identity.current.*.account_id)
  aws_region_name = one(data.aws_region.current.*.region)
  aws_partition   = one(data.aws_partition.current.*.id)

  presignup_hook_enabled        = var.presignup_hook_enabled
  presignup_hook_debug_enabled  = var.presignup_hook_debug_enabled
  presignup_hook_policy_path    = "./policy.rego"
  presignup_hook_version        = var.presignup_hook_version
  presignup_hook_policy_content = var.presignup_hook_policy_content
}

data "aws_caller_identity" "current" {
  count = local.enabled ? 1 : 0
}

data "aws_region" "current" {
  count = local.enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = local.enabled ? 1 : 0
}

# ================================================================== general ===

module "cognito_hook_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  name       = local.name
  attributes = local.name != "cognito-hooks" && length(module.this.attributes) == 0 ? ["hooks"] : []
  context    = module.this.context
}

# ---------------------------------------------------------------------- iam ---

resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0

  name        = module.cognito_hook_label.id
  description = ""

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Principal = { "Service" : "lambda.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = module.cognito_hook_label.tags
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  count = module.this.enabled ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# =========================================================== presignup-hook ===

resource "terraform_data" "presignup_hook_policy" {
  count = local.enabled && local.presignup_hook_enabled ? 1 : 0

  input = base64encode(local.presignup_hook_policy_content)

  lifecycle {
    precondition {
      condition     = startswith(local.presignup_hook_policy_content, "package cognito_hook_presignup")
      error_message = "The presignup policy content must include 'package cognito_hook_presignup'."
    }
  }
}

module "presignup_hook_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["presignup"]
  context    = module.cognito_hook_label.context
}

module "presignup_hook_code" {
  source  = "cruxstack/artifact-packager/docker"
  version = "1.3.6"
  count   = local.presignup_hook_enabled ? 1 : 0

  artifact_src_path    = "/tmp/package.zip"
  docker_build_context = abspath("${path.module}/assets/presignup-hook")
  docker_build_target  = "package"

  docker_build_args = {
    APP_VERSION                = local.presignup_hook_version
    SERVICE_OPA_POLICY_ENCODED = terraform_data.presignup_hook_policy[0].output
  }

  context = module.presignup_hook_label.context
}

resource "aws_cloudwatch_log_group" "presignup_hook" {
  count = local.presignup_hook_enabled ? 1 : 0

  name              = "/aws/lambda/${module.presignup_hook_label.id}"
  retention_in_days = 90
  tags              = module.presignup_hook_label.tags
}

resource "aws_lambda_function" "presignup_hook" {
  count = local.presignup_hook_enabled ? 1 : 0

  function_name = module.presignup_hook_label.id
  filename      = module.presignup_hook_code[0].artifact_package_path
  handler       = "bootstrap"
  runtime       = "provided.al2023"
  timeout       = 10
  role          = aws_iam_role.this[0].arn
  layers        = []

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      APP_DEBUG_ENABLED                          = local.presignup_hook_debug_enabled
      APP_LOG_LEVEL                              = var.service_log_level
      APP_POLICY_PATH                            = local.presignup_hook_policy_path
      APP_EMAIL_VERIFICATION_ENABLED             = var.presignup_hook_email_verification_enabled
      APP_EMAIL_VERIFICATION_FOR_TRIGGER_SOURCES = join(",", [for x in var.presignup_hook_email_verification_for_trigger_sources : "PreSignUp_${x}"])
      APP_EMAIL_VERIFICATION_WHITELIST           = join(",", var.presignup_hook_email_verification_whitelist)
      APP_SENDGRID_EMAIL_VERIFICATION_API_KEY    = var.sendgrid_email_verification_api_key
    }
  }

  tags = module.presignup_hook_label.tags

  depends_on = [
    module.presignup_hook_code,
    aws_cloudwatch_log_group.presignup_hook,
  ]
}

resource "aws_lambda_permission" "presignup_hook" {
  count = local.presignup_hook_enabled ? 1 : 0

  statement_id  = "allow-cognito-trigger"
  function_name = aws_lambda_function.presignup_hook[0].function_name
  action        = "lambda:InvokeFunction"
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = "arn:${local.aws_partition}:cognito-idp:${local.aws_region_name}:${local.aws_account_id}:userpool/*"
}
