# Azure DevOps to GitHub Migration Scoping Report

A comprehensive script to assess Azure DevOps organizations and generate detailed migration scoping reports for planning GitHub migrations.

## Overview

The `migration-scoping-report.sh` script automates the collection of critical information needed to plan and scope an Azure DevOps to GitHub migration. It analyzes your entire Azure DevOps organization and produces a detailed report covering repositories, pipelines, integrations, users, and metadata.

## Prerequisites

Before running the script, ensure you have the following installed:

1. **Azure CLI**: [Installation Guide](https://learn.microsoft.com/en-gb/cli/azure/install-azure-cli?view=azure-cli-latest)
   ```bash
   # Verify installation
   az --version
   ```

2. **Azure DevOps Extension**:
   ```bash
   az extension add --name azure-devops
   ```

3. **jq** (JSON processor):
   ```bash
   # macOS
   brew install jq
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install jq
   
   # Linux (RHEL/CentOS)
   sudo yum install jq
   ```

4. **curl** (usually pre-installed on most systems)

## Setup Instructions for Azure DevOps Admins

### Step 1: Generate a Personal Access Token (PAT)

1. Log into your Azure DevOps organization at `https://dev.azure.com/{your-org}`
2. Click on **User Settings** (gear icon) → **Personal Access Tokens**
3. Click **+ New Token**
4. Configure the token:
   - **Name**: "Migration Scoping Report"
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
2. Open `migration-scoping-report.sh` in a text editor
3. Update the configuration section at the top:
   ```bash
   # -------- CONFIGURATION --------
   ORG="your-org-name"              # Replace with your Azure DevOps organization name
   PAT="your-personal-access-token"  # Replace with the PAT you just created
   ```

### Step 3: Make the Script Executable

```bash
chmod +x migration-scoping-report.sh
```

### Step 4: Run the Script

```bash
./migration-scoping-report.sh
```

The script will:
- Display progress information in the console
- Generate a timestamped report file: `migration-scoping-report-YYYYMMDD-HHMMSS.txt`
- Create a `temp_migration_data/` directory with supporting data files

**Expected Runtime**: 5-15 minutes depending on organization size

## Report Contents

The generated report includes:

### 1. **Repository Count**
   - Total number of projects and repositories to migrate

### 2. **Large Repositories (>1GB)**
   - List of repositories exceeding 1GB
   - Individual repository sizes in GB

### 3. **Largest Repository**
   - Identification of the single largest repository

### 4. **Oldest Repository**
   - Repository with the earliest commit
   - First commit date and ID

### 5. **Binary/Large Files Detection**
   - Guidance on manual inspection methods
   - List of suspicious repositories to check

### 6. **Metadata Migration Requirements**
   - Work items count
   - Pull requests count
   - Projects with boards/teams
   - Migration recommendations

### 7. **Pipeline Migration Requirements**
   - Total Azure Pipelines count
   - Repositories with pipelines
   - Conversion recommendations

### 8. **Custom Integrations**
   - Service hooks and integrations
   - Integration types breakdown
   - GitHub equivalent guidance

### 9. **User Migration Requirements**
   - Total user count
   - User access level breakdown
   - Exported user list (CSV format)

### 10. **Migration Complexity Assessment**
   - Overall complexity rating (Low/Medium/High)
   - Key risk factors
   - Estimated migration timeline

## Output Files

After running the script, you'll find:

- **`migration-scoping-report-YYYYMMDD-HHMMSS.txt`** - Main report file
- **`temp_migration_data/`** directory containing:
  - `repo_details.json` - Detailed repository information
  - `users.csv` - User list for migration planning
  - `oldest_commits.txt` - Repository age data
  - `hook_types.txt` - Integration types

## Troubleshooting

### "Unauthorized" or "401" Errors
- Verify your PAT is correct and hasn't expired
- Ensure all required scopes are granted to the PAT
- Check that the organization name is correct

### "Command not found" Errors
- Ensure all prerequisites are installed
- Verify Azure CLI and extensions are up to date: `az upgrade`

### Empty or Missing Data
- Some repositories may not report size via API - these will show as 0 bytes
- If no commits exist in a repository, it won't appear in oldest repository analysis

### Script Hangs or Times Out
- Large organizations may take longer to analyze
- Check your network connection
- Consider running during off-peak hours

## Sharing the Report

Once generated, share the report file with your migration team or GitHub representative to:
- Plan migration timeline and resources
- Identify potential blockers
- Estimate GitHub licensing needs
- Design migration strategy

## Example Scripts

This repository also includes example scripts:
- `report-generator-example-1.sh` - Repository size analysis with LFS details
- `report-generator-example-2a.sh` - Basic repository metrics with oldest commits
- `report-generator-example-2b.sh` - Filter repositories by size

## Security Notes

- **Never commit your PAT to version control**
- Revoke the PAT after generating the report
- Store the report securely as it contains organizational information
- Consider using environment variables for sensitive data:
  ```bash
  export AZDO_ORG="your-org"
  export AZDO_PAT="your-pat"
  # Then reference in script: ORG="$AZDO_ORG"
  ```

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Azure DevOps API documentation
3. Open an issue in this repository