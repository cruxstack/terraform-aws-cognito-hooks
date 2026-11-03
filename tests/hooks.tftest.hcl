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
    condition     = length(aws_lambda_function.presignup_hook) == 1 && length(aws_lambda_function.postconfirmation_hook) == 0
    error_message = "only the presignup lambda should be planned"
  }

  assert {
    condition = alltrue([
      length(buildkit_artifact.hooks) == 1,
      buildkit_artifact.hooks[0].build_args.APP_VERSION == "v1.0.0",
      buildkit_artifact.hooks[0].build_args.GOARCH == "arm64",
      terraform_data.presignup_hook_policy[0].input == base64encode(var.presignup_hook_policy_content),
      buildkit_artifact.hooks[0].build_args.POSTCONFIRMATION_POLICY_ENCODED == "",
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
    condition     = length(aws_iam_role_policy.postconfirmation_hook) == 0
    error_message = "the role should not get AdminSetUserPassword without the postconfirmation hook"
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
    condition     = jsondecode(aws_iam_role_policy.postconfirmation_hook[0].policy).Statement[0].Resource[0] == "arn:aws:cognito-idp:us-east-1:111122223333:userpool/*"
    error_message = "without user pool ARNs, AdminSetUserPassword should cover the account's pools in the region"
  }
}

run "disabled" {
  command = plan

  variables {
    enabled                       = false
    presignup_hook_enabled        = true
    postconfirmation_hook_enabled = true
  }

  assert {
    condition     = length(buildkit_artifact.hooks) == 0 && length(aws_lambda_function.presignup_hook) == 0 && length(aws_iam_role.this) == 0
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
