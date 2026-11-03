# terraform-aws-cognito-hooks

This Terraform module deploys AWS Lambda functions for Amazon Cognito user
pool triggers. They run [`cruxstack/cognito-hooks-go`](https://github.com/cruxstack/cognito-hooks-go),
whose hooks make their decisions with [Rego](https://www.openpolicyagent.org/docs/policy-language)
policies you write.

| Hook                                                                                                               | What it does                                                                                       |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| [PreSignUp](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/presignup.md)                           | Allows or denies each sign-up and sets Cognito's auto-confirm and auto-verify flags. Can check the address with SendGrid first. |
| [PostConfirmation](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/postconfirmation.md)             | Replaces each newly confirmed user's password with a random one, for passwordless-only user pools. |

The module builds the function once, at `hooks_version`, and packages it with
both policies. Each enabled hook gets its own Lambda function and log group.

## Features

- PreSignUp hook with a Rego policy that allows or denies sign-ups and sets
  `autoConfirmUser`, `autoVerifyEmail`, and `autoVerifyPhone`, with optional
  SendGrid email verification as policy input
- PostConfirmation hook that scrambles each newly confirmed native user's
  password, so users sign in with passwordless factors only, with an
  optional policy to exempt users
- `arm64` (Graviton) Lambdas by default, built from a pinned version
- CloudWatch log groups with 90-day retention, X-Ray tracing, and naming and
  tags via `cloudposse/label/null`

## Usage

```hcl
module "cognito_hooks" {
  source  = "cruxstack/cognito-hooks/aws"
  version = "~> 2.0"

  presignup_hook_enabled        = true
  presignup_hook_policy_content = file("${path.module}/presignup.rego")
}

resource "aws_cognito_user_pool" "this" {
  name = "my-user-pool"

  lambda_config {
    pre_sign_up = module.cognito_hooks.presignup_hook_lambda_fn_arn
  }
}
```

with a policy such as:

```rego
package cognito_hook_presignup

import rego.v1

default result := {"action": "deny", "reason": "Sign-up is limited to example.com addresses."}

result := {"action": "allow"} if endswith(input.userAttributes.email, "@example.com")
```

The policy must start with its `package` line. See the hook's
[policy documentation](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/policies.md)
and [example policies](https://github.com/cruxstack/cognito-hooks-go/tree/v1.0.0/examples/policies).

### PostConfirmation

Only enable the PostConfirmation hook on a user pool that allows a
passwordless first factor (for example `EMAIL_OTP`), or users won't be able
to sign in. The Lambda role gets `cognito-idp:AdminSetUserPassword` on the
pools in `postconfirmation_hook_user_pool_arns`, or on every pool in the
account and region when that list is empty.

```hcl
module "cognito_hooks" {
  source  = "cruxstack/cognito-hooks/aws"
  version = "~> 2.0"

  postconfirmation_hook_enabled        = true
  postconfirmation_hook_user_pool_arns = ["arn:aws:cognito-idp:us-east-1:123456789012:userpool/us-east-1_EXAMPLE"]
}

resource "aws_cognito_user_pool" "this" {
  name = "my-user-pool"

  lambda_config {
    post_confirmation = module.cognito_hooks.postconfirmation_hook_lambda_fn_arn
  }
}
```

The policy is optional. Without one, every native user's password is
scrambled; with `postconfirmation_hook_policy_content`, it can return
`skip` for some users, such as an end-to-end test app client.

Cognito doesn't run the trigger for users created with `AdminCreateUser`.
The hook's [documentation](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/postconfirmation.md)
covers which users it reaches and the alarms to set up.

## Inputs

In addition to the variables documented below, this module includes several
other optional variables (e.g., `name`, `tags`, etc.) provided by the
`cloudposse/label/null` module. Please refer to its [documentation](https://registry.terraform.io/modules/cloudposse/label/null/latest)
for more details on these variables.

| Name                                                    | Description                                                                 |      Type      |    Default   | Required |
| ------------------------------------------------------- | --------------------------------------------------------------------------- | :------------: | :----------: | :------: |
| `hooks_version`                                         | git tag of `cognito-hooks-go` to build; `latest` builds its default branch  |    `string`    |  `"v1.0.0"`  |    no    |
| `hooks_force_rebuild_id`                                | change to force a rebuild of the artifact                                   |    `string`    |     `""`     |    no    |
| `lambda_architecture`                                   | `arm64` or `x86_64`                                                          |    `string`    |  `"arm64"`   |    no    |
| `service_log_level`                                     | log level: `debug`, `info`, `warn`, `error`                                 |    `string`    |   `"info"`   |    no    |
| `presignup_hook_enabled`                                | whether the PreSignUp hook is deployed                                      |     `bool`     |    `false`   |    no    |
| `presignup_hook_policy_content`                         | Rego policy; must start with `package cognito_hook_presignup`               |    `string`    |     `""`     |  when enabled |
| `presignup_hook_email_verification_enabled`             | verify the address with SendGrid before the policy runs                     |     `bool`     |    `false`   |    no    |
| `presignup_hook_email_verification_for_trigger_sources` | trigger sources to verify (`SignUp`, `AdminCreateUser`, `ExternalProvider`) | `list(string)` | `["SignUp"]` |    no    |
| `presignup_hook_email_verification_allowlist`           | email domains treated as valid without calling SendGrid                     | `list(string)` |     `[]`     |    no    |
| `sendgrid_email_verification_api_key`                   | SendGrid API key with Email Address Validation access (sensitive)           |    `string`    |     `""`     |  with verification |
| `postconfirmation_hook_enabled`                         | whether the PostConfirmation hook is deployed                               |     `bool`     |   `false`    |    no    |
| `postconfirmation_hook_policy_content`                  | optional Rego policy that can exempt users                                  |    `string`    |     `""`     |    no    |
| `postconfirmation_hook_user_pool_arns`                  | pools the hook may set passwords in; empty means all                        | `list(string)` |     `[]`     |    no    |

## Outputs

| Name                                  | Description                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `presignup_hook_lambda_fn_arn`        | the ARN of the PreSignUp Lambda function, or an empty string if disabled        |
| `postconfirmation_hook_lambda_fn_arn` | the ARN of the PostConfirmation Lambda function, or an empty string if disabled |

## Upgrading to v2

v2 runs [cognito-hooks-go v1](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/upgrading-to-v1.md),
which builds one binary for every hook and fails closed: a PreSignUp policy
that fails to evaluate now rejects the sign-up instead of allowing it.
Check your policies against its upgrade guide.

| v1                                            | v2                                                              |
| --------------------------------------------- | --------------------------------------------------------------- |
| `presignup_hook_version` (default `latest`)   | `hooks_version` (pinned to `v1.0.0`)                            |
| `postconfirmation_hook_version`               | `hooks_version`                                                 |
| `presignup_hook_force_rebuild_id`, `postconfirmation_hook_force_rebuild_id` | `hooks_force_rebuild_id`          |
| `presignup_hook_debug_enabled`, `postconfirmation_hook_debug_enabled` | removed; use `service_log_level = "debug"` |
| `presignup_hook_email_verification_whitelist` | `presignup_hook_email_verification_allowlist`                   |

Other changes:

- The Lambdas run on `arm64` by default. Set `lambda_architecture =
  "x86_64"` to keep the v1 architecture.
- The PreSignUp Lambda's timeout is 5 seconds, the most Cognito waits for a
  trigger.
- `sendgrid_email_verification_api_key` is `sensitive`.
- The module is checked with `terraform test` in CI.
