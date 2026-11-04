variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name" {
  type    = string
  default = "tide2ical"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,39}$", var.name))
    error_message = "name は英小文字で始まる3〜40文字の英小文字・数字・ハイフンにしてください。"
  }
}

variable "location_parameter_name" {
  description = "港の設定を JSON で入れた既存の SSM 標準 String パラメータ。値は Terraform から読まない。"
  type        = string
  default     = "/tide2ical/location"

  validation {
    condition     = can(regex("^/[a-zA-Z0-9_./-]+$", var.location_parameter_name))
    error_message = "SSM パラメータ名は / から始まるパスにしてください。"
  }
}

variable "calendar_days" {
  type    = number
  default = 90

  validation {
    condition     = var.calendar_days >= 60 && var.calendar_days <= 360 && floor(var.calendar_days) == var.calendar_days
    error_message = "生成期間は60〜360日の整数にしてください。"
  }
}

variable "notification_email" {
  description = "生成の成功・再試行後の失敗を受け取るメールアドレス。SNS の購読確認が必要。"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "通知先のメールアドレスを指定してください。"
  }
}
