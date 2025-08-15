output "presignup_hook_lambda_fn_arn" {
  value = local.presignup_hook_enabled ? aws_lambda_function.presignup_hook[0].arn : ""
}


