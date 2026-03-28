terraform {
  backend "s3" {
    bucket  = "davidstefanfiipracticawscloud"
    key     = "terraform.tfstate"
    region  = "eu-north-1"
    encrypt = true
  }
}