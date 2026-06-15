plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "google" {
  enabled = true
  version = "0.25.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
  deep_check  = false
}
