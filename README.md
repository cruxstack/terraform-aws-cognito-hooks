# terraform-aws-cognito-hooks

This Terraform module deploys AWS Lambda functions to serve as Cognito hooks.
They evaluate Open Policy Agent (OPA) policies, and the PreSignUp hook can
enrich policy input with optional SendGrid email verification.

The **PreSignUp** and **PostConfirmation** hooks are supported.

For details about the PreSignUp Lambda implementation, see the
[documentation](./assets/presignup-hook/) inside its directory. The binary is
built from [`cruxstack/cognito-hooks-go`](https://github.com/cruxstack/cognito-hooks-go)
at a ref you choose, and the OPA (Rego v1) policy is injected at build time.

## Features

- [PreSignUp hook Lambda for Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-sign-up.html)
  - customizable OPA policy to allow/deny and set response flags
    (`autoConfirmUser`, `autoVerifyEmail`, `autoVerifyPhone`)
  - optional SendGrid email verification enrichment as policy input
- [PostConfirmation hook Lambda for Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-post-confirmation.html)
  - replaces each newly confirmed native user's password with a random one, so
    users sign in with passwordless factors only (email or SMS one-time
    passwords, passkeys)
  - also runs after a forgotten-password reset; federated users are skipped
  - optional OPA policy to exempt users
- operational ergonomics
  - CloudWatch log group with 90-day retention
  - X-Ray tracing enabled
  - tags and naming via `cloudposse/label/null`

## Usage

```hcl
locals {
  # minimal allow-all policy (rego v1)
  presignup_hook_policy_content = <<-EOT
    package cognito_hook_presignup
    import rego.v1

    result := {
      "action": "allow",
      "response": {}
    }
  EOT
}

module "cognito_hooks" {
  source = "github.com/cruxstack/terraform-aws-cognito-hooks?ref=x.x.x"

  presignup_hook_enabled        = true
  presignup_hook_policy_content = local.presignup_hook_policy_content
}

resource "aws_cognito_user_pool" "this" {
  name = "my-user-pool"

  lambda_config {
    pre_sign_up = module.cognito_hooks.presignup_hook_lambda_fn_arn
  }
}
````

### PostConfirmation

Only enable the PostConfirmation hook on a user pool that allows a
passwordless first factor (for example `EMAIL_OTP`), or users won't be able to
sign in. The hook's role gets `cognito-idp:AdminSetUserPassword` on the pools in
`postconfirmation_hook_user_pool_arns`, or on every pool in the account and
region when that list is empty.

```hcl
module "cognito_hooks" {
  source = "github.com/cruxstack/terraform-aws-cognito-hooks?ref=x.x.x"

  postconfirmation_hook_enabled        = true
  postconfirmation_hook_version        = "v0.3.0"
  postconfirmation_hook_user_pool_arns = ["arn:aws:cognito-idp:us-east-1:123456789012:userpool/us-east-1_EXAMPLE"]
}

resource "aws_cognito_user_pool" "this" {
  name = "my-user-pool"

  lambda_config {
    post_confirmation = module.cognito_hooks.postconfirmation_hook_lambda_fn_arn
  }
}
```

## Policy Contract

- policy must begin with: `package cognito_hook_<hook-name>`
  - example: `package cognito_hook_presignup`
- include `import rego.v1`
- bind a `result` object:

    ```rego
    # allow
    result := {
      "action": "allow",
      "response": {
        # optional: "autoConfirmUser", "autoVerifyEmail", "autoVerifyPhone"
      }
    }
    # deny
    result := {
      "action": "deny",
      "reason": "message shown in logs"
    }
    ```

- the PostConfirmation policy (`package cognito_hook_postconfirmation`) is
  optional and returns `scramble` or `skip`:

    ```rego
    result := { "action": "skip", "reason": "message shown in logs" } if {
      input.callerContext.clientId == "1example23456789"
    } else := { "action": "scramble" }
    ```

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                                                    | Description                                                                 |      Type      |    Default   | Required |
| ------------------------------------------------------- | --------------------------------------------------------------------------- | :------------: | :----------: | :------: |
| `service_log_level`                                     | log level: `debug`, `info`, `warn`, `error`                                 |    `string`    |   `"info"`   |    no    |
| `presignup_hook_version`                                | version or git ref of the hook source (`cognito-hooks-go`)                  |    `string`    |  `"latest"`  |    no    |
| `presignup_hook_enabled`                                | whether the PreSignUp hook is deployed                                      |     `bool`     |    `false`   |    no    |
| `presignup_hook_debug_enabled`                          | enable additional debug logging                                             |     `bool`     |    `false`   |    no    |
| `presignup_hook_policy_content`                         | OPA (rego v1) policy content                                                |    `string`    |      n/a     |  **yes** |
| `presignup_hook_email_verification_enabled`             | enable SendGrid email verification enrichment                               |     `bool`     |    `false`   |    no    |
| `presignup_hook_email_verification_for_trigger_sources` | trigger sources to verify (`SignUp`, `AdminCreateUser`, `ExternalProvider`) | `list(string)` | `["SignUp"]` |    no    |
| `presignup_hook_email_verification_whitelist`           | email domains that bypass verification                                      | `list(string)` |     `[]`     |    no    |
| `sendgrid_email_verification_api_key`                   | SendGrid API key                                                            |    `string`    |     `""`     |    no    |
| `postconfirmation_hook_enabled`                         | whether the PostConfirmation hook is deployed                               |     `bool`     |   `false`    |    no    |
| `postconfirmation_hook_version`                         | version or git ref of the hook source (`v0.3.0` or later)                   |    `string`    |  `"latest"`  |    no    |
| `postconfirmation_hook_debug_enabled`                   | enable additional debug logging                                             |     `bool`     |   `false`    |    no    |
| `postconfirmation_hook_policy_content`                  | optional OPA (rego v1) policy that can exempt users                         |    `string`    |     `""`     |    no    |
| `postconfirmation_hook_user_pool_arns`                  | pools the hook may set passwords in; empty means all                        | `list(string)` |     `[]`     |    no    |

## Outputs

| Name                                  | Description                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `presignup_hook_lambda_fn_arn`        | the ARN of the Lambda function, or null if the module is disabled               |
| `postconfirmation_hook_lambda_fn_arn` | the ARN of the PostConfirmation Lambda function, or an empty string if disabled |

