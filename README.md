# Azure DevOps Data Collection Report

A script to collect data from Azure DevOps organizations.

## Overview

The `ado-data-collector.sh` script automates the collection of data from your Azure DevOps organization. It analyzes projects, repositories, pipelines, integrations, users, and metadata, producing a data-driven report.

## Prerequisites

Before running the script, ensure you have the following installed:

1. **jq** (JSON processor):
   ```bash
   # macOS
   brew install jq
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install jq
   
   # Linux (RHEL/CentOS)
   sudo yum install jq
   ```

2. **curl** (usually pre-installed on most systems)

## Setup Instructions

### Step 1: Generate a Personal Access Token (PAT)

1. Log into your Azure DevOps organization at `https://dev.azure.com/{your-org}`
2. Click on **User Settings** (gear icon) → **Personal Access Tokens**
3. Click **+ New Token**
4. Configure the token:
   - **Name**: "ADO Data Collector"
   - **Organization**: Select your organization or "All accessible organizations"
   - **Expiration**: Set to 30 days (or as needed)
   - **Scopes**: Select **Custom defined** and grant:
     - ✅ **Code**: Read
     - ✅ **Project and Team**: Read
     - ✅ **Work Items**: Read
     - ✅ **Build**: Read
     - ✅ **User Profile**: Read
     - ✅ **Service Hooks**: Read
5. Click **Create** and **copy the token** (you won't be able to see it again)

### Step 2: Configure the Script

1. Download or clone this repository
2. Open `ado-data-collector.sh` in a text editor
3. Update the configuration section at the top:
   ```bash
   # -------- CONFIGURATION --------
   ORG="your-org-name"              # Replace with your Azure DevOps organization name
   PAT="your-personal-access-token"  # Replace with the PAT you just created
   ```

### Step 3: Make the Script Executable

```bash
chmod +x ado-data-collector.sh
```

### Step 4: Run the Script

```bash
# Run with default (clean) output
./ado-data-collector.sh

# Run with debug output to see API calls
DEBUG=1 ./ado-data-collector.sh
```

The script will:
- Validate authentication before starting
- Display progress information in the console
- Generate a timestamped report file: `ado-data-report-YYYYMMDD-HHMMSS-XXXXX.txt`
- Automatically clean up temporary data on completion or interruption

**Expected Runtime**: 5-15 minutes depending on organization size

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

The generated report includes factual data only, without assessments or recommendations:

### 1. **Repository Count**
   - Total number of projects and repositories

### 2. **Large Repositories (>1GB)**
   - List of repositories exceeding 1GB with sizes

### 3. **Largest Repository**
   - Repository with the largest size

### 4. **Oldest Repository**
   - Repository with the earliest commit
   - First commit date and ID

### 5. **Binary/Large Files**
   - Note about manual inspection requirement
   - List of repositories over 1GB

### 6. **Metadata Data**
   - Work items count
   - Pull requests count
   - Projects with boards/teams

### 7. **Pipeline Data**
   - Total pipelines count
   - Repositories with pipelines

### 8. **Custom Integrations**
   - Service hooks count
   - Integration types found

### 9. **User Data**
   - Total user count
   - User access level breakdown
   - Exported user list (CSV format)

### 10. **Migration Data Summary**
   - Consolidated statistics from all sections

## Output Files

After running the script, you'll find:

- **`ado-data-report-YYYYMMDD-HHMMSS-XXXXX.txt`** - Main report file
- **`users.csv`** (if users exist) - User list with access levels and contact information

Note: Temporary data is automatically cleaned up on script completion or interruption.

## Troubleshooting

### "Authentication Failed" on Startup
- Verify your PAT is correct and hasn't expired
- Ensure all required scopes are granted to the PAT
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

- **Never commit your PAT to version control**
- Add `ado-data-report-*.txt` to `.gitignore`
- Revoke the PAT after generating the report
- Store the report securely as it contains organizational information
- Consider using environment variables for sensitive data:
  ```bash
  export AZDO_ORG="your-org"
  export AZDO_PAT="your-pat"
  # Then reference in script: ORG="$AZDO_ORG"
  ```

## Advanced Usage

### Debug Mode
Enable debug output to see all API calls:
```bash
DEBUG=1 ./ado-data-collector.sh
```

### Concurrent Execution
The script is safe for concurrent execution:
- Each run creates a unique temporary directory using process ID
- Report files include random number to prevent collisions
- Multiple instances can run simultaneously without conflicts

### Environment Variables
Set configuration via environment variables instead of editing the script:
```bash
export ORG="your-org-name"
export PAT="your-pat-token"
./ado-data-collector.sh
```

## Support

For issues or questions:
1. Review the troubleshooting section above
2. Check that all prerequisites are installed correctly
3. Verify PAT permissions and expiration
4. Open an issue in this repository with error details