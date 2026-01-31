#!/bin/bash
# Create distribution package for LiteLLM AWS deployment
# Usage: ./create-distribution.sh [version]

set -euo pipefail

VERSION=${1:-1.0.0}
PACKAGE_NAME="ADO_LiteLLM_AWS_v${VERSION}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=========================================="
echo "Creating Distribution Package"
echo "=========================================="
echo "Version: $VERSION"
echo "Package: $PACKAGE_NAME"
echo "Timestamp: $TIMESTAMP"
echo ""

# Create distribution directory
echo "Creating distribution directory..."
mkdir -p "dist/$PACKAGE_NAME"

# Copy essential files
echo "Copying files..."
cp -r azure-devops "dist/$PACKAGE_NAME/"
cp -r infrastructure "dist/$PACKAGE_NAME/"
cp -r scripts "dist/$PACKAGE_NAME/"
cp Dockerfile "dist/$PACKAGE_NAME/"
cp config.yaml "dist/$PACKAGE_NAME/"
cp .gitignore "dist/$PACKAGE_NAME/"
cp README.md "dist/$PACKAGE_NAME/"
cp QUICK_START.md "dist/$PACKAGE_NAME/"
cp TAGGING_STRATEGY.md "dist/$PACKAGE_NAME/"

# Remove unnecessary pipeline files (keep only main deployment pipelines)
echo "Cleaning up extra pipeline files..."
cd "dist/$PACKAGE_NAME/azure-devops"
rm -f azure-pipelines-litellm-config.yml
rm -f azure-pipelines-litellm-update.yml
rm -f azure-pipelines-teardown-alb.yml
rm -f azure-pipelines-teardown-database.yml
rm -f azure-pipelines-teardown-litellm.yml
rm -f azure-pipelines-teardown-network.yml
rm -f azure-pipelines-teardown-security.yml
rm -f azure-pipelines-validate.yml
cd ../../..

# Remove empty lambda directory if it exists
if [ -d "dist/$PACKAGE_NAME/infrastructure/lambda" ]; then
    if [ -z "$(ls -A "dist/$PACKAGE_NAME/infrastructure/lambda")" ]; then
        rm -rf "dist/$PACKAGE_NAME/infrastructure/lambda"
        echo "Removed empty lambda directory"
    fi
fi

# Create checksums
echo "Generating checksums..."
cd "dist/$PACKAGE_NAME"
find . -type f -exec md5sum {} \; > CHECKSUMS.md5
cd ../..

# Create tar.gz
echo "Creating tar.gz archive..."
cd dist
tar -czf "${PACKAGE_NAME}_${TIMESTAMP}.tar.gz" "$PACKAGE_NAME"
cd ..

# Create zip
echo "Creating zip archive..."
cd dist
zip -r -q "${PACKAGE_NAME}_${TIMESTAMP}.zip" "$PACKAGE_NAME"
cd ..

# Generate manifest
echo "Generating manifest..."
cat > "dist/$PACKAGE_NAME/MANIFEST.txt" <<EOF
========================================
LiteLLM AWS Deployment Package
========================================
Version: $VERSION
Created: $(date)
Package: $PACKAGE_NAME

Contents:
---------
azure-devops/           Azure DevOps pipeline YAML files
  ├── azure-pipelines-security.yml
  ├── azure-pipelines-network.yml
  ├── azure-pipelines-alb.yml
  ├── azure-pipelines-database.yml
  ├── azure-pipelines-litellm.yml
  ├── azure-pipelines-teardown.yml
  └── templates/        Reusable pipeline components
      ├── aws-cfn-deploy.yml
      ├── aws-ecr-build.yml
      └── check-prerequisites.yml

infrastructure/         CloudFormation templates
  ├── security-stack.yaml
  ├── network-stack.yaml
  ├── alb-stack.yaml
  ├── database-stack.yaml
  └── litellm-stack.yaml

scripts/                Monitoring and compliance scripts
  ├── monitor-aws-resources.sh
  ├── monitor-ado-pipelines.sh
  └── teardown-compliance-scan.sh

Root Files:
  ├── README.md                 Complete documentation
  ├── QUICK_START.md            15-minute quick start guide
  ├── TAGGING_STRATEGY.md       AWS resource tagging guide
  ├── Dockerfile                LiteLLM Docker image
  ├── config.yaml               LiteLLM configuration
  ├── .gitignore                Git ignore patterns
  └── CHECKSUMS.md5             File integrity checksums

Requirements:
-------------
- AWS Account with IAM user credentials
- Azure DevOps organization and project
- At least one LLM provider API key (OpenAI, Anthropic, or Bedrock)

Quick Start:
------------
1. Extract this package
2. Follow QUICK_START.md for step-by-step setup
3. Deploy infrastructure using Azure DevOps pipelines

Documentation:
--------------
- README.md: Complete deployment guide
- QUICK_START.md: Fast 15-minute deployment
- TAGGING_STRATEGY.md: AWS resource tagging details

Support:
--------
- GitHub: [Your repository URL]
- Documentation: See README.md

License:
--------
This deployment package is provided as-is.
LiteLLM is licensed under MIT License.

========================================
EOF

# Generate file list
echo "Generating file list..."
cd "dist/$PACKAGE_NAME"
find . -type f | sort > FILES.txt
cd ../..

# Summary
echo ""
echo "=========================================="
echo "Distribution Package Created Successfully"
echo "=========================================="
echo ""
echo "Package location:"
echo "  Directory: dist/$PACKAGE_NAME/"
echo "  Tar.gz: dist/${PACKAGE_NAME}_${TIMESTAMP}.tar.gz"
echo "  Zip: dist/${PACKAGE_NAME}_${TIMESTAMP}.zip"
echo ""

# Calculate sizes
TAR_SIZE=$(du -h "dist/${PACKAGE_NAME}_${TIMESTAMP}.tar.gz" | cut -f1)
ZIP_SIZE=$(du -h "dist/${PACKAGE_NAME}_${TIMESTAMP}.zip" | cut -f1)

echo "Package sizes:"
echo "  Tar.gz: $TAR_SIZE"
echo "  Zip: $ZIP_SIZE"
echo ""

# File counts
FILE_COUNT=$(find "dist/$PACKAGE_NAME" -type f | wc -l)
echo "Total files: $FILE_COUNT"
echo ""

echo "=========================================="
echo "Distribution is ready for release!"
echo "=========================================="
