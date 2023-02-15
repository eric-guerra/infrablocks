output "endpoint" {
  value = aws_db_instance.this.address
}

output "secret_arn" {
  value = aws_secretsmanager_secret.master.arn
}

output "security_group_id" {
  value = aws_security_group.db.id
}
