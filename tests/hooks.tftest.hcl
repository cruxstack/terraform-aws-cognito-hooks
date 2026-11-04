# Plans the module with mocked providers, so these tests need no AWS account
# and build nothing. Run with: terraform test

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/test"
    }
  }
}

mock_provider "buildkit" {}

variables {
  name                                 = "test"
  presignup_hook_policy_content        = "package cognito_hook_presignup\n\nresult := {\"actions\": [\"signup.allow\"]}\n"
  postconfirmation_hook_policy_content = ""
}

run "presignup_only" {
  command = plan

  variables {
    presignup_hook_enabled = true
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.presignup_hook) == 1,
      length(aws_lambda_function.postconfirmation_hook) == 0,
      length(aws_lambda_function.preauthentication_hook) == 0,
      length(aws_dynamodb_table.rotations) == 0,
    ])
    error_message = "only the presignup lambda should be planned"
  }

  assert {
    condition = alltrue([
      length(buildkit_artifact.hooks) == 1,
      buildkit_artifact.hooks[0].build_args.APP_VERSION == "v1.0.0",
      buildkit_artifact.hooks[0].build_args.GOARCH == "arm64",
      terraform_data.presignup_hook_policy[0].input == base64encode(var.presignup_hook_policy_content),
      buildkit_artifact.hooks[0].build_args.POSTCONFIRMATION_POLICY_ENCODED == "",
      buildkit_artifact.hooks[0].build_args.PREAUTHENTICATION_POLICY_ENCODED == "",
    ])
    error_message = "one arm64 artifact should be built at the pinned version, with only the presignup policy"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.presignup_hook[0].runtime == "provided.al2023",
      aws_lambda_function.presignup_hook[0].handler == "bootstrap",
      aws_lambda_function.presignup_hook[0].architectures[0] == "arm64",
      aws_lambda_function.presignup_hook[0].timeout == 5,
    ])
    error_message = "the presignup lambda should run the go binary on arm64 with cognito's 5 second limit"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_PRESIGNUP_ENABLED == "true",
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_PRESIGNUP_POLICY_PATH == "./presignup.rego",
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_LOG_LEVEL == "info",
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_EMAIL_VERIFICATION_ENABLED == "false",
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_EMAIL_VERIFICATION_FOR_TRIGGER_SOURCES == "PreSignUp_SignUp",
      !contains(keys(aws_lambda_function.presignup_hook[0].environment[0].variables), "APP_POSTCONFIRMATION_ENABLED"),
    ])
    error_message = "the presignup environment should follow the cognito-hooks-go v1 contract"
  }

  assert {
    condition = length(setintersection(keys(aws_lambda_function.presignup_hook[0].environment[0].variables), [
      "APP_POLICY_PATH", "APP_DEBUG_ENABLED", "APP_DEBUG_DATA_PATH", "APP_EMAIL_VERIFICATION_WHITELIST",
    ])) == 0
    error_message = "the presignup environment must not set variables cognito-hooks-go v1 rejects"
  }

  assert {
    condition     = length(aws_iam_role_policy.postconfirmation_hook) == 0 && length(aws_iam_role_policy.preauthentication_hook) == 0
    error_message = "the role should not get AdminSetUserPassword without the postconfirmation or preauthentication hook"
  }
}

run "both_hooks_on_x86_64" {
  command = plan

  variables {
    presignup_hook_enabled                                = true
    presignup_hook_email_verification_enabled             = true
    presignup_hook_email_verification_for_trigger_sources = ["SignUp", "AdminCreateUser"]
    presignup_hook_email_verification_allowlist           = ["example.com", "example.org"]
    sendgrid_email_verification_api_key                   = "SG.example"

    postconfirmation_hook_enabled        = true
    postconfirmation_hook_policy_content = "package cognito_hook_postconfirmation\n\nresult := {\"actions\": [\"password.replace\"]}\n"
    postconfirmation_hook_user_pool_arns = ["arn:aws:cognito-idp:us-east-1:111122223333:userpool/us-east-1_EXAMPLE"]

    lambda_architecture = "x86_64"
  }

  assert {
    condition = alltrue([
      length(buildkit_artifact.hooks) == 1,
      buildkit_artifact.hooks[0].build_args.GOARCH == "amd64",
      terraform_data.postconfirmation_hook_policy[0].input == base64encode(var.postconfirmation_hook_policy_content),
      aws_lambda_function.presignup_hook[0].architectures[0] == "x86_64",
      aws_lambda_function.postconfirmation_hook[0].architectures[0] == "x86_64",
    ])
    error_message = "both lambdas should share one amd64 artifact with both policies"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_EMAIL_VERIFICATION_ENABLED == "true",
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_EMAIL_VERIFICATION_FOR_TRIGGER_SOURCES == "PreSignUp_SignUp,PreSignUp_AdminCreateUser",
      aws_lambda_function.presignup_hook[0].environment[0].variables.APP_EMAIL_VERIFICATION_ALLOWLIST == "example.com,example.org",
    ])
    error_message = "email verification settings should be passed to the presignup lambda"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.postconfirmation_hook[0].timeout == 5,
      aws_lambda_function.postconfirmation_hook[0].environment[0].variables.APP_POSTCONFIRMATION_ENABLED == "true",
      aws_lambda_function.postconfirmation_hook[0].environment[0].variables.APP_POSTCONFIRMATION_POLICY_PATH == "./postconfirmation.rego",
      !contains(keys(aws_lambda_function.postconfirmation_hook[0].environment[0].variables), "APP_PRESIGNUP_ENABLED"),
      !contains(keys(aws_lambda_function.postconfirmation_hook[0].environment[0].variables), "APP_DEBUG_ENABLED"),
    ])
    error_message = "the postconfirmation environment should follow the cognito-hooks-go v1 contract"
  }

  assert {
    condition     = tolist(jsondecode(aws_iam_role_policy.postconfirmation_hook[0].policy).Statement[0].Resource) == tolist(var.postconfirmation_hook_user_pool_arns)
    error_message = "AdminSetUserPassword should be scoped to the given user pools"
  }
}

run "postconfirmation_without_policy" {
  command = plan

  variables {
    postconfirmation_hook_enabled = true
  }

  assert {
    condition = alltrue([
      length(terraform_data.postconfirmation_hook_policy) == 0,
      length(terraform_data.presignup_hook_policy) == 0,
      buildkit_artifact.hooks[0].build_args.POSTCONFIRMATION_POLICY_ENCODED == "",
      aws_lambda_function.postconfirmation_hook[0].environment[0].variables.APP_POSTCONFIRMATION_POLICY_PATH == "",
    ])
    error_message = "without a policy, the postconfirmation lambda should replace every native user's password"
  }

  assert {
    condition = alltrue([
      length(aws_dynamodb_table.rotations) == 0,
      !contains(keys(aws_lambda_function.postconfirmation_hook[0].environment[0].variables), "APP_POSTCONFIRMATION_ROTATION_TABLE"),
      output.preauthentication_hook_rotation_table_name == "",
    ])
    error_message = "without the preauthentication hook, there is no rotation table to record replacements in"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.postconfirmation_hook[0].policy).Statement[0].Resource[0] == "arn:aws:cognito-idp:us-east-1:111122223333:userpool/*"
    error_message = "without user pool ARNs, AdminSetUserPassword should cover the account's pools in the region"
  }
}

run "disabled" {
  command = plan

  variables {
    enabled                              = false
    presignup_hook_enabled               = true
    postconfirmation_hook_enabled        = true
    preauthentication_hook_enabled       = true
    preauthentication_hook_rotate_before = "2026-11-01T00:00:00Z"
  }

  assert {
    condition = alltrue([
      length(buildkit_artifact.hooks) == 0,
      length(aws_lambda_function.presignup_hook) == 0,
      length(aws_lambda_function.preauthentication_hook) == 0,
      length(aws_dynamodb_table.rotations) == 0,
      length(aws_iam_role.this) == 0,
    ])
    error_message = "a disabled module should plan nothing"
  }
}

run "verification_requires_a_key" {
  command = plan

  variables {
    presignup_hook_enabled                    = true
    presignup_hook_email_verification_enabled = true
  }

  expect_failures = [terraform_data.presignup_hook_policy]
}

run "presignup_policy_must_start_with_its_package" {
  command = plan

  variables {
    presignup_hook_enabled        = true
    presignup_hook_policy_content = "# a comment first\npackage cognito_hook_presignup\n"
  }

  expect_failures = [terraform_data.presignup_hook_policy]
}

run "rejects_unknown_architectures" {
  command = plan

  variables {
    presignup_hook_enabled = true
    lambda_architecture    = "arm"
  }

  expect_failures = [var.lambda_architecture]
}

# password rotation is off by default: the hook gets no table, no aws
# permissions, and no rotation settings, even when they are given
run "preauthentication_without_password_rotation" {
  command = plan

  variables {
    hooks_version                              = "v1.1.0"
    preauthentication_hook_enabled             = true
    preauthentication_hook_rotate_before       = "2026-11-01T00:00:00Z"
    preauthentication_hook_rotation_table_name = "existing-rotations"

    postconfirmation_hook_enabled = true
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.preauthentication_hook) == 1,
      length(aws_lambda_permission.preauthentication_hook) == 1,
      length(aws_dynamodb_table.rotations) == 0,
      length(aws_iam_role_policy.preauthentication_hook) == 0,
      output.preauthentication_hook_rotation_table_name == "",
    ])
    error_message = "without password rotation, the hook should get no rotation table or aws permissions"
  }

  assert {
    condition = aws_lambda_function.preauthentication_hook[0].environment[0].variables == tomap({
      APP_LOG_LEVEL                                   = "info"
      APP_PREAUTHENTICATION_ENABLED                   = "true"
      APP_PREAUTHENTICATION_POLICY_PATH               = ""
      APP_PREAUTHENTICATION_PASSWORD_ROTATION_ENABLED = "false"
    })
    error_message = "without password rotation, the hook should get no rotation settings"
  }

  assert {
    condition     = !contains(keys(aws_lambda_function.postconfirmation_hook[0].environment[0].variables), "APP_POSTCONFIRMATION_ROTATION_TABLE")
    error_message = "without password rotation, the postconfirmation hook has no table to record replacements in"
  }
}

run "preauthentication_creates_its_table" {
  command = plan

  variables {
    hooks_version                                    = "v1.1.0"
    preauthentication_hook_enabled                   = true
    preauthentication_hook_password_rotation_enabled = true
    preauthentication_hook_rotate_before             = "2026-11-01T00:00:00Z"
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.preauthentication_hook) == 1,
      length(aws_lambda_function.presignup_hook) == 0,
      length(aws_lambda_function.postconfirmation_hook) == 0,
      length(aws_lambda_permission.preauthentication_hook) == 1,
      aws_cloudwatch_log_group.preauthentication_hook[0].name == "/aws/lambda/test-hooks-preauthentication",
      buildkit_artifact.hooks[0].build_args.APP_VERSION == "v1.1.0",
      buildkit_artifact.hooks[0].build_args.PREAUTHENTICATION_POLICY_ENCODED == "",
    ])
    error_message = "the preauthentication lambda should be planned on its own, built at the given version, without a policy"
  }

  assert {
    condition = alltrue([
      aws_lambda_function.preauthentication_hook[0].function_name == "test-hooks-preauthentication",
      aws_lambda_function.preauthentication_hook[0].runtime == "provided.al2023",
      aws_lambda_function.preauthentication_hook[0].handler == "bootstrap",
      aws_lambda_function.preauthentication_hook[0].timeout == 5,
    ])
    error_message = "the preauthentication lambda should run the go binary with cognito's 5 second limit"
  }

  assert {
    condition = alltrue([
      length(aws_dynamodb_table.rotations) == 1,
      aws_dynamodb_table.rotations[0].name == "test-hooks-password-rotations",
      aws_dynamodb_table.rotations[0].billing_mode == "PAY_PER_REQUEST",
      aws_dynamodb_table.rotations[0].hash_key == "sub",
      length(aws_dynamodb_table.rotations[0].attribute) == 1,
      one(aws_dynamodb_table.rotations[0].attribute).name == "sub",
      one(aws_dynamodb_table.rotations[0].attribute).type == "S",
      aws_dynamodb_table.rotations[0].server_side_encryption[0].enabled,
      aws_dynamodb_table.rotations[0].point_in_time_recovery[0].enabled,
      output.preauthentication_hook_rotation_table_name == "test-hooks-password-rotations",
    ])
    error_message = "the module should create an encrypted, on-demand rotation table keyed by sub, with point-in-time recovery"
  }

  assert {
    condition = aws_lambda_function.preauthentication_hook[0].environment[0].variables == tomap({
      APP_LOG_LEVEL                                   = "info"
      APP_PREAUTHENTICATION_ENABLED                   = "true"
      APP_PREAUTHENTICATION_POLICY_PATH               = ""
      APP_PREAUTHENTICATION_PASSWORD_ROTATION_ENABLED = "true"
      APP_PREAUTHENTICATION_ROTATE_BEFORE             = "2026-11-01T00:00:00Z"
      APP_PREAUTHENTICATION_ROTATION_TABLE            = "test-hooks-password-rotations"
    })
    error_message = "the preauthentication environment should follow the cognito-hooks-go v1.1 contract"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.preauthentication_hook[0].policy).Statement == [
      {
        Effect   = "Allow"
        Action   = ["cognito-idp:AdminGetUser", "cognito-idp:AdminSetUserPassword"]
        Resource = ["arn:aws:cognito-idp:us-east-1:111122223333:userpool/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = ["arn:aws:dynamodb:us-east-1:111122223333:table/test-hooks-password-rotations"]
      },
    ]
    error_message = "the role should look up users and set passwords in the account's pools, and read and write only the rotation table"
  }
}

run "preauthentication_with_an_existing_table" {
  command = plan

  variables {
    hooks_version                                    = "v1.1.0"
    preauthentication_hook_enabled                   = true
    preauthentication_hook_password_rotation_enabled = true
    preauthentication_hook_rotate_before             = "2026-10-31T20:00:00-04:00"
    preauthentication_hook_rotation_table_name       = "existing-rotations"
    preauthentication_hook_user_pool_arns            = ["arn:aws:cognito-idp:us-east-1:111122223333:userpool/us-east-1_EXAMPLE"]
    preauthentication_hook_policy_content            = "package cognito_hook_preauthentication\n\nresult := {\"actions\": []}\n"

    postconfirmation_hook_enabled = true
  }

  assert {
    condition = alltrue([
      length(aws_dynamodb_table.rotations) == 0,
      output.preauthentication_hook_rotation_table_name == "existing-rotations",
      aws_lambda_function.preauthentication_hook[0].environment[0].variables.APP_PREAUTHENTICATION_ROTATION_TABLE == "existing-rotations",
      aws_lambda_function.preauthentication_hook[0].environment[0].variables.APP_PREAUTHENTICATION_ROTATE_BEFORE == "2026-10-31T20:00:00-04:00",
    ])
    error_message = "the hook should use the existing table instead of creating one"
  }

  assert {
    condition     = aws_lambda_function.postconfirmation_hook[0].environment[0].variables.APP_POSTCONFIRMATION_ROTATION_TABLE == "existing-rotations"
    error_message = "the postconfirmation hook should record its replacements in the same table"
  }

  assert {
    condition = alltrue([
      terraform_data.preauthentication_hook_policy[0].input == base64encode(var.preauthentication_hook_policy_content),
      aws_lambda_function.preauthentication_hook[0].environment[0].variables.APP_PREAUTHENTICATION_POLICY_PATH == "./preauthentication.rego",
    ])
    error_message = "the preauthentication policy should be packaged with the function"
  }

  assert {
    condition = alltrue([
      tolist(jsondecode(aws_iam_role_policy.preauthentication_hook[0].policy).Statement[0].Resource) == tolist(var.preauthentication_hook_user_pool_arns),
      jsondecode(aws_iam_role_policy.preauthentication_hook[0].policy).Statement[1].Resource == ["arn:aws:dynamodb:us-east-1:111122223333:table/existing-rotations"],
    ])
    error_message = "the role should be scoped to the given user pools and the existing table"
  }
}

# a branch or "latest" can't be checked, so it is allowed
run "preauthentication_with_an_untagged_version" {
  command = plan

  variables {
    hooks_version                  = "latest"
    preauthentication_hook_enabled = true
  }

  assert {
    condition     = length(aws_lambda_function.preauthentication_hook) == 1
    error_message = "the preauthentication lambda should be planned"
  }
}

run "preauthentication_needs_hooks_v1_1" {
  command = plan

  variables {
    hooks_version                  = "v1.0.0"
    preauthentication_hook_enabled = true
  }

  expect_failures = [aws_lambda_function.preauthentication_hook]
}

run "password_rotation_needs_a_cutoff" {
  command = plan

  variables {
    hooks_version                                    = "v1.1.0"
    preauthentication_hook_enabled                   = true
    preauthentication_hook_password_rotation_enabled = true
  }

  expect_failures = [aws_lambda_function.preauthentication_hook]
}

run "preauthentication_cutoff_must_be_rfc3339" {
  command = plan

  variables {
    hooks_version                        = "v1.1.0"
    preauthentication_hook_enabled       = true
    preauthentication_hook_rotate_before = "2026-11-01"
  }

  expect_failures = [var.preauthentication_hook_rotate_before]
}

run "preauthentication_cutoff_must_have_passed" {
  command = plan

  variables {
    hooks_version                        = "v1.1.0"
    preauthentication_hook_enabled       = true
    preauthentication_hook_rotate_before = "2999-01-01T00:00:00Z"
  }

  expect_failures = [var.preauthentication_hook_rotate_before]
}

run "preauthentication_policy_must_start_with_its_package" {
  command = plan

  variables {
    hooks_version                         = "v1.1.0"
    preauthentication_hook_enabled        = true
    preauthentication_hook_rotate_before  = "2026-11-01T00:00:00Z"
    preauthentication_hook_policy_content = "package cognito_hook_postconfirmation\n"
  }

  expect_failures = [terraform_data.preauthentication_hook_policy]
}
