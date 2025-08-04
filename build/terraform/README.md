# Media file processing pipeline
The processing pipelines in this folder handle the media processing logic for converting high-resolution media files to lower-resolution versions, called proxies.
These proxies are then used in an AI-driven media intelligence analysis process, which produces the following outcomes:
* Video Segmentation: A Cloud run job triggers Gemini to analyze the proxy file and provide in and out timecodes for each individual shot. 
* Contextual Analysis: A separate Gemini Cloud run job provides text-based context for each shot segment.
* Customization note: Gemini can easily be trained through prompting to capture specific features in the context output, further extending the tool's functionality.
* Persist text to BigQuery: Timecodes and context are persisted in BigQuery in text form.
Vector Embeddings created and stored

## Deployment
Use terraform to deploy the required resource for the media file processing pipeline.

1. Create the `terraform.tfvars` file by making a copy of the `terraform.tfvars.example` file.
```sh
cp terraform.tfvars.example terraform.tfvars
```
1. Update terraform.tfvars with your Google Cloud project ID and desired names for the Cloud Storage buckets (for high-resolution and low-resolution media files).
1. Initialize Terraform and apply the configuration to create the resources:
```sh
terraform init
terraform apply
```
