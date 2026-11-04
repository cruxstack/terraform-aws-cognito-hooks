locals {
  name            = coalesce(module.this.name, var.name, "cognito-hooks")
  enabled         = module.this.enabled
  aws_account_id  = one(data.aws_caller_identity.current[*].account_id)
  aws_region_name = one(data.aws_region.current[*].region)
  aws_partition   = one(data.aws_partition.current[*].partition)

  presignup_hook_enabled        = local.enabled && var.presignup_hook_enabled
  presignup_hook_policy_content = var.presignup_hook_policy_content

  postconfirmation_hook_enabled        = local.enabled && var.postconfirmation_hook_enabled
  postconfirmation_hook_policy_content = var.postconfirmation_hook_policy_content

  preauthentication_hook_enabled        = local.enabled && var.preauthentication_hook_enabled
  preauthentication_hook_policy_content = var.preauthentication_hook_policy_content

  # password rotation is an opt-in feature of the preauthentication hook; the
  # table, its iam permissions, and its settings exist only when it is on
  password_rotation_enabled = local.preauthentication_hook_enabled && var.preauthentication_hook_password_rotation_enabled

  # every lambda runs the same go binary, packaged with every policy
  hooks_enabled = local.presignup_hook_enabled || local.postconfirmation_hook_enabled || local.preauthentication_hook_enabled
  hooks_goarch  = var.lambda_architecture == "arm64" ? "arm64" : "amd64"

  presignup_hook_policy_path         = "./presignup.rego"
  postconfirmation_hook_policy_path  = local.postconfirmation_hook_policy_content != "" ? "./postconfirmation.rego" : ""
  preauthentication_hook_policy_path = local.preauthentication_hook_policy_content != "" ? "./preauthentication.rego" : ""

  # major and minor version of a vX.Y.Z hooks_version; null for "latest" or
  # another git ref, which the module can't check
  hooks_version_tag = try(regex("^v(\\d+)\\.(\\d+)\\.\\d+", var.hooks_version), null)
  hooks_version_has_preauthentication = local.hooks_version_tag == null || try(
    tonumber(local.hooks_version_tag[0]) > 1 || (tonumber(local.hooks_version_tag[0]) == 1 && tonumber(local.hooks_version_tag[1]) >= 1),
    false,
  )

  # password rotation's records of when the hooks replaced each password;
  # the postconfirmation hook records its replacements there too
  rotation_table_created = local.password_rotation_enabled && var.preauthentication_hook_rotation_table_name == ""
  rotation_table_name = !local.password_rotation_enabled ? "" : (
    local.rotation_table_created ? aws_dynamodb_table.rotations[0].name : var.preauthentication_hook_rotation_table_name
  )
  rotation_table_arn = !local.password_rotation_enabled ? "" : (
    "arn:${local.aws_partition}:dynamodb:${local.aws_region_name}:${local.aws_account_id}:table/${local.rotation_table_name}"
  )

  # cognito waits at most 5 seconds for a trigger
  hooks_timeout = 5
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

resource "aws_iam_role_policy_attachment" "lambda_execution" {
  count = local.enabled ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

moved {
  from = aws_iam_role_policy_attachment.ssm_managed_instance_core
  to   = aws_iam_role_policy_attachment.lambda_execution
}

# -------------------------------------------------------------------- build ---

resource "terraform_data" "presignup_hook_policy" {
  count = local.presignup_hook_enabled ? 1 : 0

  input = base64encode(local.presignup_hook_policy_content)

  lifecycle {
    precondition {
      condition     = startswith(local.presignup_hook_policy_content, "package cognito_hook_presignup")
      error_message = "The presignup policy content must start with 'package cognito_hook_presignup'."
    }
    precondition {
      condition     = !var.presignup_hook_email_verification_enabled || var.sendgrid_email_verification_api_key != ""
      error_message = "sendgrid_email_verification_api_key is required when presignup_hook_email_verification_enabled is true."
    }
  }
}

resource "terraform_data" "postconfirmation_hook_policy" {
  count = local.postconfirmation_hook_enabled && local.postconfirmation_hook_policy_content != "" ? 1 : 0

  input = base64encode(local.postconfirmation_hook_policy_content)

  lifecycle {
    precondition {
      condition     = startswith(local.postconfirmation_hook_policy_content, "package cognito_hook_postconfirmation")
      error_message = "The postconfirmation policy content must start with 'package cognito_hook_postconfirmation'."
    }
  }
}

resource "terraform_data" "preauthentication_hook_policy" {
  count = local.preauthentication_hook_enabled && local.preauthentication_hook_policy_content != "" ? 1 : 0

  input = base64encode(local.preauthentication_hook_policy_content)

  lifecycle {
    precondition {
      condition     = startswith(local.preauthentication_hook_policy_content, "package cognito_hook_preauthentication")
      error_message = "The preauthentication policy content must start with 'package cognito_hook_preauthentication'."
    }
  }
}

# transitional: forget pre-buildkit module.presignup_hook_code from state on upgrade
removed {
  from = module.presignup_hook_code

  lifecycle {
    destroy = false
  }
}

data "buildkit_context" "hooks" {
  count = local.hooks_enabled ? 1 : 0

  path = abspath("${path.module}/assets/hooks")
}

# the hooks function (cruxstack/cognito-hooks-go) built at hooks_version,
# packaged with the presignup, postconfirmation, and preauthentication
# policies
resource "buildkit_artifact" "hooks" {
  count = local.hooks_enabled ? 1 : 0

  build_context     = abspath("${path.module}/assets/hooks")
  dockerfile        = "Dockerfile"
  target            = "package"
  artifact_src_path = "/tmp/package.zip"
  artifact_src_type = "zip"
  artifact_dst_path = "${path.module}/dist/hooks/package.zip"

  build_args = {
    APP_VERSION                      = var.hooks_version
    GOARCH                           = local.hooks_goarch
    PRESIGNUP_POLICY_ENCODED         = try(terraform_data.presignup_hook_policy[0].output, "")
    POSTCONFIRMATION_POLICY_ENCODED  = try(terraform_data.postconfirmation_hook_policy[0].output, "")
    PREAUTHENTICATION_POLICY_ENCODED = try(terraform_data.preauthentication_hook_policy[0].output, "")
  }

  triggers = {
    context          = data.buildkit_context.hooks[0].digest
    app_version      = var.hooks_version
    goarch           = local.hooks_goarch
    force_rebuild_id = var.hooks_force_rebuild_id
  }
}

# =========================================================== presignup-hook ===

module "presignup_hook_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["presignup"]
  context    = module.cognito_hook_label.context
}

resource "aws_cloudwatch_log_group" "presignup_hook" {
  count = local.presignup_hook_enabled ? 1 : 0

  name              = "/aws/lambda/${module.presignup_hook_label.id}"
  retention_in_days = 90
  tags              = module.presignup_hook_label.tags
}

resource "aws_lambda_function" "presignup_hook" {
  count = local.presignup_hook_enabled ? 1 : 0

  function_name    = module.presignup_hook_label.id
  filename         = buildkit_artifact.hooks[0].artifact_path
  source_code_hash = buildkit_artifact.hooks[0].artifact_sha256
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = [var.lambda_architecture]
  timeout          = local.hooks_timeout
  role             = aws_iam_role.this[0].arn
  layers           = []

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      APP_LOG_LEVEL                              = var.service_log_level
      APP_PRESIGNUP_ENABLED                      = "true"
      APP_PRESIGNUP_POLICY_PATH                  = local.presignup_hook_policy_path
      APP_EMAIL_VERIFICATION_ENABLED             = tostring(var.presignup_hook_email_verification_enabled)
      APP_EMAIL_VERIFICATION_FOR_TRIGGER_SOURCES = join(",", [for x in var.presignup_hook_email_verification_for_trigger_sources : "PreSignUp_${x}"])
      APP_EMAIL_VERIFICATION_ALLOWLIST           = join(",", var.presignup_hook_email_verification_allowlist)
      APP_SENDGRID_EMAIL_VERIFICATION_API_KEY    = var.sendgrid_email_verification_api_key
    }
  }

  tags = module.presignup_hook_label.tags

  depends_on = [
    buildkit_artifact.hooks,
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

# ==================================================== postconfirmation-hook ===

module "postconfirmation_hook_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["postconfirmation"]
  context    = module.cognito_hook_label.context
}

resource "aws_iam_role_policy" "postconfirmation_hook" {
  count = local.postconfirmation_hook_enabled ? 1 : 0

  name = "postconfirmation-hook"
  role = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["cognito-idp:AdminSetUserPassword"]
      Resource = length(var.postconfirmation_hook_user_pool_arns) > 0 ? var.postconfirmation_hook_user_pool_arns : [
        "arn:${local.aws_partition}:cognito-idp:${local.aws_region_name}:${local.aws_account_id}:userpool/*",
      ]
    }]
  })
}

resource "aws_cloudwatch_log_group" "postconfirmation_hook" {
  count = local.postconfirmation_hook_enabled ? 1 : 0

  name              = "/aws/lambda/${module.postconfirmation_hook_label.id}"
  retention_in_days = 90
  tags              = module.postconfirmation_hook_label.tags
}

resource "aws_lambda_function" "postconfirmation_hook" {
  count = local.postconfirmation_hook_enabled ? 1 : 0

  function_name    = module.postconfirmation_hook_label.id
  filename         = buildkit_artifact.hooks[0].artifact_path
  source_code_hash = buildkit_artifact.hooks[0].artifact_sha256
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = [var.lambda_architecture]
  timeout          = local.hooks_timeout
  role             = aws_iam_role.this[0].arn
  layers           = []

  tracing_config {
    mode = "Active"
  }

  environment {
    # with password rotation, record each replacement in its table so the
    # preauthentication hook doesn't replace the password again at the user's
    # first sign-in
    variables = merge(
      {
        APP_LOG_LEVEL                    = var.service_log_level
        APP_POSTCONFIRMATION_ENABLED     = "true"
        APP_POSTCONFIRMATION_POLICY_PATH = local.postconfirmation_hook_policy_path
      },
      local.password_rotation_enabled ? { APP_POSTCONFIRMATION_ROTATION_TABLE = local.rotation_table_name } : {},
    )
  }

  tags = module.postconfirmation_hook_label.tags

  depends_on = [
    buildkit_artifact.hooks,
    aws_cloudwatch_log_group.postconfirmation_hook,
  ]
}

resource "aws_lambda_permission" "postconfirmation_hook" {
  count = local.postconfirmation_hook_enabled ? 1 : 0

  statement_id  = "allow-cognito-trigger"
  function_name = aws_lambda_function.postconfirmation_hook[0].function_name
  action        = "lambda:InvokeFunction"
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = "arn:${local.aws_partition}:cognito-idp:${local.aws_region_name}:${local.aws_account_id}:userpool/*"
}

# =================================================== preauthentication-hook ===

module "preauthentication_hook_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["preauthentication"]
  context    = module.cognito_hook_label.context
}

module "rotation_table_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["password-rotations"]
  context    = module.cognito_hook_label.context
}

# password rotation's record of when the hooks last replaced each user's
# password, keyed by the user's sub
resource "aws_dynamodb_table" "rotations" {
  count = local.rotation_table_created ? 1 : 0

  name         = module.rotation_table_label.id
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sub"

  attribute {
    name = "sub"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = module.rotation_table_label.tags
}

# only password rotation calls aws, so the hook has no permissions without it
resource "aws_iam_role_policy" "preauthentication_hook" {
  count = local.password_rotation_enabled ? 1 : 0

  name = "preauthentication-hook"
  role = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["cognito-idp:AdminGetUser", "cognito-idp:AdminSetUserPassword"]
        Resource = length(var.preauthentication_hook_user_pool_arns) > 0 ? var.preauthentication_hook_user_pool_arns : [
          "arn:${local.aws_partition}:cognito-idp:${local.aws_region_name}:${local.aws_account_id}:userpool/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = [local.rotation_table_arn]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "preauthentication_hook" {
  count = local.preauthentication_hook_enabled ? 1 : 0

  name              = "/aws/lambda/${module.preauthentication_hook_label.id}"
  retention_in_days = 90
  tags              = module.preauthentication_hook_label.tags
}

resource "aws_lambda_function" "preauthentication_hook" {
  count = local.preauthentication_hook_enabled ? 1 : 0

  function_name    = module.preauthentication_hook_label.id
  filename         = buildkit_artifact.hooks[0].artifact_path
  source_code_hash = buildkit_artifact.hooks[0].artifact_sha256
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = [var.lambda_architecture]
  timeout          = local.hooks_timeout
  role             = aws_iam_role.this[0].arn
  layers           = []

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = merge(
      {
        APP_LOG_LEVEL                                   = var.service_log_level
        APP_PREAUTHENTICATION_ENABLED                   = "true"
        APP_PREAUTHENTICATION_POLICY_PATH               = local.preauthentication_hook_policy_path
        APP_PREAUTHENTICATION_PASSWORD_ROTATION_ENABLED = tostring(local.password_rotation_enabled)
      },
      local.password_rotation_enabled ? {
        APP_PREAUTHENTICATION_ROTATE_BEFORE  = var.preauthentication_hook_rotate_before
        APP_PREAUTHENTICATION_ROTATION_TABLE = local.rotation_table_name
      } : {},
    )
  }

  tags = module.preauthentication_hook_label.tags

  lifecycle {
    # cognito-hooks-go before v1.1.0 doesn't know the hook, so the function
    # wouldn't start and every sign-in would fail
    precondition {
      condition     = local.hooks_version_has_preauthentication
      error_message = "The preauthentication hook needs hooks_version v1.1.0 or later of cognito-hooks-go."
    }
    precondition {
      condition     = !local.password_rotation_enabled || var.preauthentication_hook_rotate_before != ""
      error_message = "preauthentication_hook_rotate_before is required when preauthentication_hook_password_rotation_enabled is true."
    }
  }

  depends_on = [
    buildkit_artifact.hooks,
    aws_cloudwatch_log_group.preauthentication_hook,
  ]
}

resource "aws_lambda_permission" "preauthentication_hook" {
  count = local.preauthentication_hook_enabled ? 1 : 0

  statement_id  = "allow-cognito-trigger"
  function_name = aws_lambda_function.preauthentication_hook[0].function_name
  action        = "lambda:InvokeFunction"
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = "arn:${local.aws_partition}:cognito-idp:${local.aws_region_name}:${local.aws_account_id}:userpool/*"
}
