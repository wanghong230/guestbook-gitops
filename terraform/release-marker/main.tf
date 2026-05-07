# Placeholder module: provisions a "release marker" with no cloud-side effects.
# Real resources go here later — see README.md.

# A fresh release ID is minted whenever the stage or image tag changes.
resource "random_id" "release" {
  byte_length = 8

  keepers = {
    stage     = var.stage
    image_tag = var.image_tag
  }
}

# `terraform_data` is a stateful no-op resource — useful for recording derived
# values that should appear in the apply graph and the saved state.
resource "terraform_data" "marker" {
  input = {
    release_id = random_id.release.hex
    stage      = var.stage
    image_tag  = var.image_tag
    note       = "Placeholder. Replace with real cloud resources when ready."
  }
}
