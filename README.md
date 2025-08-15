# `terraform-aws-cognito-hooks`

**NOT READY: This module is in development. It will be released soon"

## Features

## Usage

```hcl
locals {
  # example policy that allows all requests
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
  source = "github.com/cruxstack/terraform-aws-cognito-hooks?ref=<version>"

  presignup_hook_enabled                    = true
  presignup_hook_policy_content             = local.presignup_hook_policy_content
}
```

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                                    | Description                                                                           |   Type   |  Default   | Required |
|-----------------------------------------|---------------------------------------------------------------------------------------|:--------:|:----------:|:--------:|
| `service_log_level`                     | The log level for the service. It must be one of 'debug', 'info', 'warn', or 'error'. | `string` | `"info"`   |    no    |
| `presignup_hook_version`                | Version or git ref of the source code                                                 | `string` | `"latest"` |    no    |
| `presignup_hook_enabled`                | Whether or not the presignup hook is enabled.                                         |  `bool`  |  `false`   |    no    |
| `presignup_hook_policy_content`         | The content of the Open Policy Agent policy.                                          | `string` |    n/a     |   yes    |
| `sendgrid_email_verification_api_key`   | The SendGrid API key used to interact with its API.                                   | `string` |   `""`     |   no     |
| `sendgrid_email_verification_enabled`   | Toggle to use email verification.                                                     |  `bool`  |  `false`   |   no     |

## Outputs

| Name                         | Description                                                        |
|------------------------------|--------------------------------------------------------------------|
| `prehook_hook_lambda_fn_arn` | The ARN of the Lambda function, or null if the module is disabled. |

