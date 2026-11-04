output "presignup_hook_lambda_fn_arn" {
  value = local.presignup_hook_enabled ? aws_lambda_function.presignup_hook[0].arn : ""
}

output "postconfirmation_hook_lambda_fn_arn" {
  value = local.postconfirmation_hook_enabled ? aws_lambda_function.postconfirmation_hook[0].arn : ""
}

output "preauthentication_hook_lambda_fn_arn" {
  value = local.preauthentication_hook_enabled ? aws_lambda_function.preauthentication_hook[0].arn : ""
}

output "preauthentication_hook_rotation_table_name" {
  value = local.rotation_table_name
}
