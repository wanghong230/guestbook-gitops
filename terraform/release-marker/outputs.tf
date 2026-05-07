output "release_id" {
  description = "Hex string identifying this release. Stable for a given (stage, image_tag) pair."
  value       = random_id.release.hex
}

output "marker" {
  description = "Full release marker record."
  value       = terraform_data.marker.output
}
