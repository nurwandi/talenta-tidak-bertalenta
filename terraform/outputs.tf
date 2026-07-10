output "ecr_repository_url" {
  value = data.aws_ecr_repository.this.repository_url
}

output "lambda_function_names" {
  value = [for f in aws_lambda_function.clock : f.function_name]
}
