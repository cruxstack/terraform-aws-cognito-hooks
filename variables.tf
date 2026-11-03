# ================================================================== general ===

variable "service_log_level" {
  description = "Log level of the hook Lambdas: 'debug', 'info', 'warn', or 'error'. 'debug' logs every event, including user attributes."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.service_log_level)
    error_message = "Service log level must be one of 'debug', 'info', 'warn', or 'error'"
  }
}

variable "hooks_version" {
  description = "Git tag of cruxstack/cognito-hooks-go to build for the hook Lambdas. 'latest' builds its default branch, which can include breaking changes."
  type        = string
  default     = "v1.0.0"
  nullable    = false
}

variable "hooks_force_rebuild_id" {
  description = "Change this value to force a rebuild of the hooks artifact."
  type        = string
  default     = ""
  nullable    = false
}

variable "lambda_architecture" {
  description = "Instruction set of the hook Lambdas: 'arm64' (Graviton, lower cost) or 'x86_64'."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.lambda_architecture)
    error_message = "lambda_architecture must be 'arm64' or 'x86_64'."
  }
}

# ----------------------------------------------------------- presignup_hook ---

variable "presignup_hook_enabled" {
  description = "Whether or not the presignup hook is enabled."
  type        = bool
  default     = false
}

variable "presignup_hook_policy_content" {
  description = "The PreSignUp Rego policy. It must start with 'package cognito_hook_presignup'."
  type        = string
  default     = ""
}

variable "presignup_hook_email_verification_enabled" {
  type        = bool
  description = "Verify the user's email address with SendGrid before the policy runs."
  default     = false
}

variable "presignup_hook_email_verification_for_trigger_sources" {
  type        = list(string)
  description = "PreSignUp trigger sources to verify the email address for: SignUp, AdminCreateUser, or ExternalProvider."
  default     = ["SignUp"]

  validation {
    condition     = alltrue([for x in var.presignup_hook_email_verification_for_trigger_sources : contains(["SignUp", "AdminCreateUser", "ExternalProvider"], x)])
    error_message = "Valid trigger sources: SignUp, AdminCreateUser, and ExternalProvider"
  }
}

variable "presignup_hook_email_verification_allowlist" {
  type        = list(string)
  description = "Email domains that are treated as valid without calling SendGrid."
  default     = []
}

variable "sendgrid_email_verification_api_key" {
  type        = string
  description = "SendGrid API key with Email Address Validation access. Required when presignup_hook_email_verification_enabled is true."
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------- postconfirmation_hook ---

variable "postconfirmation_hook_enabled" {
  description = "Whether or not the post confirmation hook is enabled. It replaces each newly confirmed native user's password with a random one, so users sign in with passwordless factors only."
  type        = bool
  default     = false
}

variable "postconfirmation_hook_policy_content" {
  description = "Optional PostConfirmation Rego policy that can exempt users from the password scramble. It must start with 'package cognito_hook_postconfirmation'. When empty, every native user's password is scrambled."
  type        = string
  default     = ""
}

variable "postconfirmation_hook_user_pool_arns" {
  description = "ARNs of the user pools where the hook may set passwords. When empty, the hook may set passwords in any user pool in the account and region."
  type        = list(string)
  default     = []
}
