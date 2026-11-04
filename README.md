# terraform-aws-cognito-hooks

This Terraform module deploys AWS Lambda functions for Amazon Cognito user
pool triggers. They run [`cruxstack/cognito-hooks-go`](https://github.com/cruxstack/cognito-hooks-go),
whose hooks make their decisions with [Rego](https://www.openpolicyagent.org/docs/policy-language)
policies you write.

| Hook                                                                                                               | What it does                                                                                       |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| [PreSignUp](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/presignup.md)                           | Allows or denies each sign-up and sets Cognito's auto-confirm and auto-verify flags. Can check the address with SendGrid first. |
| [PostConfirmation](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/postconfirmation.md)             | Replaces each newly confirmed user's password with a random one, for passwordless-only user pools. |
| [PreAuthentication](https://github.com/cruxstack/cognito-hooks-go/blob/v1.1.0/docs/preauthentication.md)           | Runs at each sign-in and carries out the features you enable. Opt-in password rotation replaces a password set before a cutoff time with a random one, so exposed passwords stop working. |

The module builds the function once, at `hooks_version`, and packages it with
every policy. Each enabled hook gets its own Lambda function and log group.

## Features

- PreSignUp hook whose Rego policy returns actions that allow or deny
  sign-ups and set Cognito's auto-confirm and auto-verify flags
  (`signup.allow`, `signup.deny`, `user.confirm`, `email.verify`,
  `phone.verify`), with optional SendGrid email verification as policy input
- PostConfirmation hook that replaces each confirmed native user's password
  with a random one (`password.replace`), so users sign in with
  passwordless factors only, with an optional policy to keep some passwords
  (`password.skip`)
- PreAuthentication hook with an optional policy and opt-in features, such
  as password rotation, which replaces each native user's password at their
  first sign-in after a cutoff, recorded in a DynamoDB table the module
  creates
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

result := {"actions": actions}

actions contains "signup.allow"

# a denial wins over the allow
actions contains {"action": "signup.deny", "reason": "Sign-up is limited to example.com addresses."} if {
	not endswith(input.userAttributes.email, "@example.com")
}
```

The policy returns a list of
[actions](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/policies.md#actions)
and must start with its `package` line. See the hook's
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
replaced; with `postconfirmation_hook_policy_content`, it can return
`password.skip` for some users, such as an end-to-end test app client.

Cognito doesn't run the trigger for users created with `AdminCreateUser`.
The hook's [documentation](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/postconfirmation.md)
covers which users it reaches and the alarms to set up.

### PreAuthentication

The PreAuthentication hook runs at each sign-in, evaluates its optional
policy, and carries out the features you enable. It needs `hooks_version`
v1.1.0 or later of cognito-hooks-go. With no feature enabled, it lets every
sign-in continue and gets no AWS permissions, so you can attach it to the
user pool first and turn features on later without changing the pool.

Its one feature today is password rotation, which is off by default. With
`preauthentication_hook_password_rotation_enabled`, when a native,
confirmed user signs in, the hook replaces their password with a random one
unless the hooks have replaced it since
`preauthentication_hook_rotate_before`. A password exposed before then stops
working, while users who sign in with a passwordless factor notice nothing.
Each user's password is replaced once, at their first sign-in after the
cutoff, and moving the cutoff later replaces every password once more.
Password rotation needs the same passwordless first factor as
PostConfirmation.

```hcl
module "cognito_hooks" {
  source  = "cruxstack/cognito-hooks/aws"
  version = "~> 2.1"

  hooks_version = "v1.1.0"

  preauthentication_hook_enabled                   = true
  preauthentication_hook_password_rotation_enabled = true
  preauthentication_hook_rotate_before             = "2026-11-01T00:00:00Z"
  preauthentication_hook_user_pool_arns            = ["arn:aws:cognito-idp:us-east-1:123456789012:userpool/us-east-1_EXAMPLE"]
}

resource "aws_cognito_user_pool" "this" {
  name = "my-user-pool"

  lambda_config {
    pre_authentication = module.cognito_hooks.preauthentication_hook_lambda_fn_arn
  }
}
```

- **Rotation table.** Password rotation records when the hooks replaced
  each password in a DynamoDB table: on-demand, keyed by `sub`, encrypted
  with the AWS managed key, with point-in-time recovery. The module creates
  it, or uses the table in `preauthentication_hook_rotation_table_name`.
  When the PostConfirmation hook is enabled too, it records its replacements
  in the same table, so a newly confirmed user doesn't get another new
  password at their first sign-in. Turning password rotation off destroys a
  table the module created, and every password is replaced once more if you
  turn it on again.
- **IAM.** With password rotation, the Lambda role gets
  `cognito-idp:AdminGetUser` and `cognito-idp:AdminSetUserPassword` on the
  pools in `preauthentication_hook_user_pool_arns` (every pool in the
  account and region when the list is empty), and `dynamodb:GetItem` and
  `dynamodb:PutItem` on the table.
- **Policy.** `preauthentication_hook_policy_content` can return
  `password.skip` for some users, such as end-to-end test accounts. Match
  them by `sub` or username, never by app client ID: a client without a
  secret has a public ID, so anyone could sign in through it and keep a
  leaked password working.
- **Failures.** Password rotation rejects a sign-in rather than let Cognito
  check an old password, for example when `AdminSetUserPassword` is
  throttled. Turning it off stops the replacements altogether.

Whether the new password applies to the sign-in that triggered the
replacement, or only to the next one, hasn't been verified. The hook's
[documentation](https://github.com/cruxstack/cognito-hooks-go/blob/v1.1.0/docs/preauthentication.md)
describes how to test it in a test user pool, and covers failure handling,
quotas, and the alarms to set up.

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
| `preauthentication_hook_enabled`                        | whether the PreAuthentication hook is deployed; needs `hooks_version` v1.1.0 or later | `bool` |  `false`     |    no    |
| `preauthentication_hook_policy_content`                 | optional Rego policy that returns actions for the enabled features          |    `string`    |     `""`     |    no    |
| `preauthentication_hook_password_rotation_enabled`      | whether the hook replaces passwords set before the cutoff at sign-in        |     `bool`     |   `false`    |    no    |
| `preauthentication_hook_rotate_before`                  | password rotation's cutoff, an RFC 3339 timestamp that has passed           |    `string`    |     `""`     | with password rotation |
| `preauthentication_hook_user_pool_arns`                 | pools password rotation may look users up and set passwords in; empty means all | `list(string)` |  `[]`     |    no    |
| `preauthentication_hook_rotation_table_name`            | existing DynamoDB table (partition key `sub`, a string) for password rotation; empty creates one | `string` | `""` | no |

## Outputs

| Name                                  | Description                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `presignup_hook_lambda_fn_arn`        | the ARN of the PreSignUp Lambda function, or an empty string if disabled        |
| `postconfirmation_hook_lambda_fn_arn` | the ARN of the PostConfirmation Lambda function, or an empty string if disabled |
| `preauthentication_hook_lambda_fn_arn` | the ARN of the PreAuthentication Lambda function, or an empty string if disabled |
| `preauthentication_hook_rotation_table_name` | the name of password rotation's table, or an empty string without password rotation |

## Upgrading to v2

v2 runs [cognito-hooks-go v1](https://github.com/cruxstack/cognito-hooks-go/blob/v1.0.0/docs/upgrading-to-v1.md),
which builds one binary for every hook and fails closed: a PreSignUp policy
that fails to evaluate now rejects the sign-up instead of allowing it.
Policies now return a list of actions (`{"actions": ["signup.allow"]}`
instead of `{"action": "allow"}`); its upgrade guide shows how to convert
them.

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
