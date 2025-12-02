# Azure DevOps Data Collection Report

A script to collect data from Azure DevOps organizations.

## Overview

The `ado-data-collector.sh` script automates the collection of data from your Azure DevOps organization. It analyzes projects, repositories, pipelines, integrations, users, and metadata, producing a data-driven report.

## Prerequisites

Before running the script, ensure you have the following:

### Azure DevOps Organization Settings

1. **Third-Party application access via OAuth** must be enabled:
   - Go to your Azure DevOps organization: `https://dev.azure.com/{your-org}`
   - Click **Organization settings** (bottom left)
   - Navigate to **Policies** under Security
   - Enable **Third-party application access via OAuth**
   
   ![Third-party OAuth setting](docs/images/third-party-oauth-setting.png)

2. **Azure account access**: Your Azure account must have access to the Azure DevOps organization you want to scan

### Required Tools

1. **Azure CLI** (for authentication):
   ```bash
   # macOS
   brew install azure-cli
   
   # Linux (Ubuntu/Debian)
   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
   
   # Linux (RHEL/CentOS)
   sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
   sudo dnf install azure-cli
   ```

2. **jq** (JSON processor):
   ```bash
   # macOS
   brew install jq
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install jq
   
   # Linux (RHEL/CentOS)
   sudo yum install jq
   ```

3. **curl** (usually pre-installed on most systems)

4. **git** (required only if using `SCAN_LARGE_FILES=1` option):
   ```bash
   # macOS
   brew install git
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install git
   
   # Linux (RHEL/CentOS)
   sudo yum install git
   ```

## Setup Instructions

### Step 1: Login to Azure

The script uses Azure AD authentication via the Azure CLI. This is more secure than PAT tokens and provides access to all Azure DevOps APIs including Advanced Security.

```bash
# Login to Azure (opens browser for authentication)
az login

# Verify you're logged in
az account show
```

**Note**: Your Azure account must have access to the Azure DevOps organization you want to scan.

### Step 2: Configure the Script

1. Download or clone this repository
2. Open `ado-data-collector.sh` in a text editor
3. Update the organization name in the configuration section:
   ```bash
   # -------- CONFIGURATION --------
   DEBUG=${DEBUG:-0}                 # Set to 1 for debug output
   SCAN_LARGE_FILES=${SCAN_LARGE_FILES:-0}  # Set to 1 to scan for large files
   ORG="your-org-name"               # Replace with your Azure DevOps organization name
   ```

### Step 3: Make the Script Executable

```bash
chmod +x ado-data-collector.sh
```

### Step 4: Run the Script

```bash
# Run with default mode (API-only, faster)
./ado-data-collector.sh

# Run with large file scanning (clones repos, slower but detects individual large files)
SCAN_LARGE_FILES=1 ./ado-data-collector.sh

# Run with debug output to see API calls
DEBUG=1 ./ado-data-collector.sh

# Combine options
DEBUG=1 SCAN_LARGE_FILES=1 ./ado-data-collector.sh
```

The script will:
- Validate authentication before starting
- Display progress information in the console
- Generate a timestamped report file: `ado-data-report-YYYYMMDD-HHMMSS-XXXXX.txt`
- Automatically clean up temporary data on completion or interruption

**Expected Runtime**: 
- **Default mode**: 5-15 minutes depending on organization size
- **With SCAN_LARGE_FILES=1**: 10-30 minutes (clones repositories for file scanning)

## Features

### Robust Error Handling
- Early authentication validation with clear error messages
- Graceful handling of API failures and network timeouts
- Automatic retry logic for transient failures (30-second timeout, 2 retries)
- Concurrent execution safety with unique temp directories per run

### Edge Case Support
- Handles project/repository names with spaces, special characters, UTF-8, quotes, and backslashes
- Safely processes empty organizations or projects with no repositories
- Properly encodes all URLs for API compatibility
- Locale-independent sorting for consistent results

## Report Contents

The generated report includes factual data only, it does not make assessments or recommendations:

### 1. **Repository Count**
   - Total number of projects and repositories

### 2. **Repositories Over 1GB (API-Reported Size)**
   - List of repositories exceeding 1GB based on Azure DevOps API size metric
   - Sizes shown in GB

### 3. **Largest Repository (API-Reported Size)**
   - Repository with the largest API-reported size
   - Size shown in MB or GB

### 4. **Oldest Repository**
   - Repository with the earliest commit
   - First commit date and ID

### 5. **Large Files Scan (Individual File Sizes)**
   - **Default mode**: Shows instructions for manual inspection
   - **With SCAN_LARGE_FILES=1**: Automatically scans Git history for files >50MB
     - Lists all large files with exact sizes
     - Includes files from entire Git history (even if deleted)
     - Provides GitHub migration guidance (50MB warning, 100MB block)

### 6. **Metadata Data**
   - Work items count
   - Pull requests count
   - Projects with boards/teams

### 7. **Pipeline Data**
   - Total pipelines count
   - Repositories with pipelines

### 8. **Security Scanning (Advanced Security)**
   - **If Advanced Security is enabled**: Reports on security alerts
     - Secret scanning alerts (credentials, tokens, API keys)
     - Dependency scanning alerts (vulnerable packages)
     - Code scanning alerts (security vulnerabilities)
     - Repositories with security alerts
   - **If not enabled**: Provides information about the feature and alternatives
   - Note: Azure DevOps Advanced Security is a paid add-on feature

### 9. **Custom Integrations**
   - Service hooks count
   - Integration types found

### 10. **User Data**
   - Total user count
   - User access level breakdown
   - Exported user list (CSV format)

### 11. **Migration Data Summary**
   - Consolidated statistics from all sections
   - Includes large file counts when SCAN_LARGE_FILES=1
   - Includes security alert counts if Advanced Security is enabled

## Output Files

After running the script, you'll find:

- **`ado-data-report-YYYYMMDD-HHMMSS-XXXXX.txt`** - Main report file
- **`users.csv`** (if users exist) - User list with access levels and contact information

Note: Temporary data is automatically cleaned up on script completion or interruption.

## Troubleshooting

### "Authentication Failed" on Startup
- Run `az login` to authenticate with Azure
- Verify your Azure account has access to the Azure DevOps organization
- Run `az account show` to confirm you're logged in
- Check that the organization name is correct (no spaces or special characters in URL)

### "Command not found: jq"
- Install jq using the commands in the Prerequisites section

### Network Timeouts
- Script includes 30-second timeout with 2 automatic retries
- Check your network connection if multiple API calls fail
- Large organizations may take longer but should complete within timeout limits

### Empty or Missing Data in Report
- Some repositories may not report size via API
- Empty projects (no repositories) are automatically skipped
- If all projects are empty, script will exit early with a message

### Script Interrupted (Ctrl+C)
- Temporary files are automatically cleaned up
- Report file (if partially created) will remain
- Safe to re-run the script

## Using the Report

The generated report provides factual data to support migration planning discussions. Use the data to:
- Understand the scope of content to migrate
- Identify which repositories contain the most data
- Document existing integrations and their types
- Export user lists for account mapping planning

## Example Scripts

This repository also includes example scripts:
- `report-generator-example-1.sh` - Repository size analysis with LFS details
- `report-generator-example-2a.sh` - Basic repository metrics with oldest commits
- `report-generator-example-2b.sh` - Filter repositories by size

## Security Best Practices

- Add `ado-data-report-*.txt` to `.gitignore`
- Store the report securely as it contains organizational information
- Azure AD tokens are automatically managed and expire after 1 hour
- No secrets are stored in the script - authentication uses `az login`
- Consider using environment variables for configuration:
  ```bash
  export ORG="your-org"
  # Then reference in script or pass directly
  ```

## Advanced Usage

### Debug Mode
Enable debug output to see all API calls:
```bash
DEBUG=1 ./ado-data-collector.sh
```

### Large File Scanning
Enable automatic large file detection (requires Git):
```bash
SCAN_LARGE_FILES=1 ./ado-data-collector.sh
```

**How it works:**
- Clones each repository as a bare repository (faster, no working directory)
- Scans entire Git object database for all blobs
- Detects files >50MB anywhere in Git history
- Identifies files even if they were deleted in later commits
- Reports exact file sizes and paths

**When to use:**
- Planning GitHub migration (GitHub warns at 50MB, blocks at 100MB)
- Identifying candidates for Git LFS conversion
- Understanding true repository size vs API-reported size
- Finding large files that may have been deleted but still bloat the repo

**Performance note:** This mode is slower as it clones repositories, but provides accurate file-level analysis.

### Concurrent Execution
The script is safe for concurrent execution:
- Each run creates a unique temporary directory using process ID
- Report files include random number to prevent collisions
- Multiple instances can run simultaneously without conflicts

### Environment Variables
Set configuration via environment variables instead of editing the script:
```bash
export ORG="your-org-name"
export SCAN_LARGE_FILES=1
export DEBUG=1
./ado-data-collector.sh
```

**Note**: Authentication is handled via `az login` - no PAT required.

## Support

For issues or questions:
1. Review the troubleshooting section above
2. Check that all prerequisites are installed correctly
3. Verify you're logged in with `az login` and have access to the organization
4. Open an issue in this repository with error details
