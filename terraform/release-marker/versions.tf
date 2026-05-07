terraform {
  required_version = ">= 1.6"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # NOTE: local backend by default. Each Kargo promotion runs in an ephemeral
  # pod, so state is discarded between runs — fine for this placeholder.
  # When real cloud resources land here, switch to a remote backend, e.g.:
  #
  #   backend "s3" {
  #     bucket         = "my-tf-state"
  #     key            = "guestbook/${var.stage}.tfstate"
  #     region         = "us-west-2"
  #     dynamodb_table = "tf-locks"
  #     encrypt        = true
  #   }
}
