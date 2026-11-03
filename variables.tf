# ================================================================== general ===

variable "service_log_level" {
  description = "The log level for the service. It must be one of 'debug', 'info', 'warn', 'error', 'panic' or 'fatal'."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.service_log_level)
    error_message = "Service log level must be one of 'debug', 'info', 'warn', or 'error'"
  }
}

# ----------------------------------------------------------- presignup_hook ---


variable "presignup_hook_enabled" {
  description = "Whether or not the presignup hook is enabled."
  type        = bool
  default     = false
}

variable "presignup_hook_debug_enabled" {
  type    = bool
  default = false
}

variable "presignup_hook_version" {
  type    = string
  default = "latest"
}

variable "presignup_hook_force_rebuild_id" {
  description = "ID to force rebuilding the presignup hook Lambda function source code. Increment this value to trigger a rebuild."
  type        = string
  default     = ""
}

variable "presignup_hook_policy_content" {
  description = "The content of the Open Policy Agent policy."
  type        = string
  default     = ""
}

variable "presignup_hook_email_verification_enabled" {
  type        = bool
  description = "Toggle to use email verification."
  default     = false
}

variable "presignup_hook_email_verification_for_trigger_sources" {
  type        = list(string)
  description = "List of Cognito trigger sources that invoke the email verification service."
  default     = ["SignUp"]

  validation {
    condition     = alltrue([for x in var.presignup_hook_email_verification_for_trigger_sources : contains(["SignUp", "AdminCreateUser", "ExternalProvider"], x)])
    error_message = "Valid trigger sources: SignUp, AdminCreateUser, and ExternalProvider"
  }
}

variable "presignup_hook_email_verification_whitelist" {
  type        = list(string)
  description = "List of email domains that bypass email validation."
  default     = []
}

variable "sendgrid_email_verification_api_key" {
  type        = string
  description = "The SendGrid API key used to interact with its Email Verification API."
  default     = ""

  validation {
    condition     = !var.presignup_hook_email_verification_enabled || (var.presignup_hook_email_verification_enabled && try(length(var.sendgrid_email_verification_api_key) > 0, false))
    error_message = "SendGrid Email Verification is enabled but API Key is not set."
  }
}

# ---------------------------------------------------- postconfirmation_hook ---

variable "postconfirmation_hook_enabled" {
  description = "Whether or not the post confirmation hook is enabled. It replaces each newly confirmed native user's password with a random one, so users sign in with passwordless factors only."
  type        = bool
  default     = false
}

variable "postconfirmation_hook_debug_enabled" {
  type    = bool
  default = false
}

variable "postconfirmation_hook_version" {
  description = "Version or git ref of the hook source (cognito-hooks-go). The post confirmation hook needs a version that includes `cmd/postconfirmation`."
  type        = string
  default     = "latest"
}

variable "postconfirmation_hook_force_rebuild_id" {
  description = "ID to force rebuilding the post confirmation hook Lambda function source code. Increment this value to trigger a rebuild."
  type        = string
  default     = ""
}

variable "postconfirmation_hook_policy_content" {
  description = "Optional Open Policy Agent policy that can exempt users from the password scramble. When empty, every native user's password is scrambled."
  type        = string
  default     = ""
}

variable "postconfirmation_hook_user_pool_arns" {
  description = "ARNs of the user pools where the hook may set passwords. When empty, the hook may set passwords in any user pool in the account and region."
  type        = list(string)
  default     = []
}
