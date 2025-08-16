# terraform-aws-cognito-hooks

This Terraform module deploys an AWS Lambda function to serve as a Cognito
hook. It evaluates Open Policy Agent (OPA) policies to allow or deny the
request and can enrich policy input with optional SendGrid email verification.

_For now, only the **PreSignUp** hook is supported._

For details about the PreSignUp Lambda implementation, see the
[documentation](./assets/presignup-hook/) inside its directory. The binary is
built from [`cruxstack/cognito-hooks-go`](https://github.com/cruxstack/cognito-hooks-go)
at a ref you choose, and the OPA (Rego v1) policy is injected at build time.

## Features

- [PreSignUp hook Lambda for Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-sign-up.html)
  - customizable OPA policy to allow/deny and set response flags
    (`autoConfirmUser`, `autoVerifyEmail`, `autoVerifyPhone`)
  - optional SendGrid email verification enrichment as policy input
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

## Outputs

| Name                           | Description                                                       |
| ------------------------------ | ----------------------------------------------------------------- |
| `presignup_hook_lambda_fn_arn` | the ARN of the Lambda function, or null if the module is disabled |

