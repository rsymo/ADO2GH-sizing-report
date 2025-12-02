#!/bin/bash

# ========================================
# Azure DevOps Data Collector
# ========================================
# This script collects data from Azure DevOps organizations
# for GitHub migration planning.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - jq installed for JSON parsing
#
# Usage:
#   az login
#   ./ado-data-collector.sh

# Note: set -e is NOT used to allow graceful error handling

# -------- CONFIGURATION --------
# Set DEBUG=1 to see detailed API calls, DEBUG=0 for cleaner output
DEBUG=${DEBUG:-0}
# Set SCAN_LARGE_FILES=1 to clone repos and scan for large files (slower but accurate)
SCAN_LARGE_FILES=${SCAN_LARGE_FILES:-0}
# Azure DevOps organization name
ORG="${ORG:-}"
if [ -z "$ORG" ]; then
    echo "ERROR: ORG environment variable is not set"
    echo "Please set it to your Azure DevOps organization name:"
    echo "  export ORG=your-org-name"
    echo "  ./ado-data-collector.sh"
    echo ""
    echo "Or set it inline:"
    echo "  ORG=your-org-name ./ado-data-collector.sh"
    exit 1
fi
ORG_URL="https://dev.azure.com/$ORG"

# Report output file with microsecond precision and random component for uniqueness
REPORT_FILE="ado-data-report-$(date +%Y%m%d-%H%M%S)-${RANDOM}.txt"
# Use PID to create unique temp directory to avoid conflicts with concurrent runs
TEMP_DATA_DIR="temp_migration_data_$$"
mkdir -p "$TEMP_DATA_DIR"

# Set up cleanup trap to remove temp directory and secure files on exit (success or failure)
# This ensures bearer tokens in curl config are always cleaned up
cleanup() {
    rm -rf "$TEMP_DATA_DIR"
    # Explicitly remove curl config if it exists outside temp dir
    [ -n "$CURL_CONFIG_FILE" ] && rm -f "$CURL_CONFIG_FILE" 2>/dev/null
}
trap cleanup EXIT INT TERM

# API version
API_VERSION="7.1"

# -------- AUTHENTICATION --------
# Get Azure AD Bearer token using Azure CLI
# Azure DevOps resource ID: 499b84ac-1321-427f-aa17-267ca6975798

echo "Authenticating with Azure AD..."

if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI is not installed"
    echo "Please install Azure CLI: https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo "ERROR: Not logged in to Azure CLI"
    echo "Please run: az login"
    exit 1
fi

# Get Bearer token for Azure DevOps
ADO_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null)

if [ -z "$ADO_TOKEN" ]; then
    echo "ERROR: Failed to get Azure AD token for Azure DevOps"
    echo "Please ensure you have access to Azure DevOps organization: $ORG"
    exit 1
fi

echo "Authentication successful!"
echo ""

# -------- HELPER FUNCTIONS --------

# Create a secure curl config file with authentication header
# This prevents token exposure in process listings
# Use mktemp for secure, unpredictable filename to prevent race conditions
CURL_CONFIG_FILE=$(mktemp "$TEMP_DATA_DIR/curl_config.XXXXXX")
chmod 600 "$CURL_CONFIG_FILE"  # Ensure restrictive permissions from the start

create_curl_config() {
    # Write headers to config file (already has 600 permissions from mktemp)
    cat > "$CURL_CONFIG_FILE" << EOF
header = "Authorization: Bearer $ADO_TOKEN"
header = "Accept: application/json"
EOF
}

# Initialize curl config on first call
create_curl_config

# Function to refresh Azure AD token for long-running operations
# Tokens typically expire after 1 hour, so refresh before long operations
refresh_token() {
    [ "$DEBUG" = "1" ] && echo "[DEBUG] Refreshing Azure AD token..." >&2
    local new_token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null)
    if [ -n "$new_token" ]; then
        ADO_TOKEN="$new_token"
        # Recreate curl config with new token
        create_curl_config
        [ "$DEBUG" = "1" ] && echo "[DEBUG] Token refreshed successfully" >&2
    else
        [ "$DEBUG" = "1" ] && echo "[DEBUG] WARNING: Failed to refresh token, continuing with existing token" >&2
    fi
}

# Function to make Azure DevOps API calls (GET requests)
# Uses secure curl config file to avoid token exposure in process listings
call_api() {
    local endpoint="$1"
    [ "$DEBUG" = "1" ] && echo "[DEBUG] GET: $endpoint" >&2
    curl -s -f -L --max-time 30 --retry 2 --retry-delay 1 \
        --config "$CURL_CONFIG_FILE" \
        "$endpoint" 2>/dev/null || echo "API_ERROR"
}

# Function to make Azure DevOps API POST calls
call_api_post() {
    local endpoint="$1"
    local data="$2"
    [ "$DEBUG" = "1" ] && echo "[DEBUG] POST: $endpoint" >&2
    curl -s -f -L --max-time 30 --retry 2 --retry-delay 1 \
        --config "$CURL_CONFIG_FILE" \
        -H "Content-Type: application/json" \
        -X POST -d "$data" "$endpoint" 2>/dev/null || echo "API_ERROR"
}

# Function to safely extract a numeric value from JSON.
# Returns 0 if the API call fails (input is "API_ERROR"), JSON is invalid, or the path doesn't exist.
safe_jq_count() {
    local json="$1"
    local path="$2"
    if [ "$json" = "API_ERROR" ] || ! echo "$json" | jq empty 2>/dev/null; then
        echo "0"
    else
        echo "$json" | jq -r "$path // 0" 2>/dev/null || echo "0"
    fi
}

# Function to URL encode strings (for project names with special characters)
# This version properly handles UTF-8 and all special characters
url_encode() {
    local string="$1"
    local length="${#string}"
    local encoded=""
    local pos c o
    
    for (( pos=0; pos<length; pos++ )); do
        c="${string:pos:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) 
                # Keep safe characters as-is
                encoded+="$c" 
                ;;
            *)
                # Convert to hex using printf - works with UTF-8
                printf -v o '%%%02X' "'$c"
                encoded+="$o"
                ;;
        esac
    done
    echo "$encoded"
}

# Function to write section header to report
write_section() {
    local title="$1"
    echo "" | tee -a "$REPORT_FILE"
    echo "========================================" | tee -a "$REPORT_FILE"
    echo "$title" | tee -a "$REPORT_FILE"
    echo "========================================" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
}

# -------- START REPORT --------
echo "Generating Azure DevOps Data Collection Report..." | tee "$REPORT_FILE"
echo "Organization: $ORG" | tee -a "$REPORT_FILE"
echo "Generated: $(date)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Validate authentication and organization access early
echo "Validating organization access..." | tee -a "$REPORT_FILE"
validation_test=$(call_api "$ORG_URL/_apis/projects?%24top=1&api-version=$API_VERSION")
if [ "$validation_test" = "API_ERROR" ]; then
    echo "ERROR: Failed to access Azure DevOps organization" | tee -a "$REPORT_FILE"
    echo "Please verify:" | tee -a "$REPORT_FILE"
    echo "  1. Organization name is correct: $ORG" | tee -a "$REPORT_FILE"
    echo "  2. You are logged in with 'az login'" | tee -a "$REPORT_FILE"
    echo "  3. Your account has access to this organization" | tee -a "$REPORT_FILE"
    exit 1
fi
echo "Organization access confirmed!" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# ========================================
# 1. REPOSITORY COUNT
# ========================================
write_section "1. Repository Count"

echo "Collecting repository data..." | tee -a "$REPORT_FILE"

# Get all projects
projects_response=$(call_api "$ORG_URL/_apis/projects?api-version=$API_VERSION")

# Validate JSON response
if [ "$projects_response" = "API_ERROR" ] || ! echo "$projects_response" | jq empty 2>/dev/null; then
    echo "ERROR: Failed to retrieve projects from Azure DevOps API" | tee -a "$REPORT_FILE"
    echo "Response: $projects_response" | tee -a "$REPORT_FILE"
    exit 1
fi

# Use while-read loop to handle project names with spaces/special characters (Bash 3.2 compatible)
# Filter out null and empty values
projects=()
while IFS= read -r project; do
    [ -n "$project" ] && projects+=("$project")
done < <(echo "$projects_response" | jq -r '.value[].name | select(. != null and . != "")')

# Check if we actually have any projects
if [ ${#projects[@]} -eq 0 ] || [ -z "${projects[0]:-}" ]; then
    echo "WARNING: No projects found in organization" | tee -a "$REPORT_FILE"
    echo "Total Projects: 0" | tee -a "$REPORT_FILE"
    echo "Total Repositories: 0" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Nothing to migrate - exiting" | tee -a "$REPORT_FILE"
    exit 0
fi

total_repos=0
project_count=0

# Create temporary file for repo details
REPO_DETAILS_FILE="$TEMP_DATA_DIR/repo_details.json"
echo "[]" > "$REPO_DETAILS_FILE"

for project in "${projects[@]}"; do
    # Skip empty project names (shouldn't happen after filtering, but safety check)
    [ -z "$project" ] && continue
    
    project_count=$((project_count + 1))
    
    # URL encode project name to handle special characters
    project_encoded=$(url_encode "$project")
    
    # Get repos for this project
    repos_json=$(call_api "$ORG_URL/$project_encoded/_apis/git/repositories?api-version=$API_VERSION")
    
    # Validate JSON response before processing
    if [ "$repos_json" = "API_ERROR" ] || ! echo "$repos_json" | jq empty 2>/dev/null; then
        echo "WARNING: Failed to retrieve repositories for project '$project' (skipping)" | tee -a "$REPORT_FILE"
        continue
    fi
    
    repo_count=$(echo "$repos_json" | jq -r '.value | length')
    total_repos=$((total_repos + repo_count))
    
    # Store repo details for later analysis
    # Use jq --arg to safely pass project name (handles quotes and backslashes)
    echo "$repos_json" | jq -c --arg proj "$project" '.value[] | {project: $proj, name: .name, id: .id, size: .size, defaultBranch: .defaultBranch, remoteUrl: .remoteUrl}' >> "$REPO_DETAILS_FILE.tmp"
done

# Consolidate all repo details into a single JSON array
if [ -f "$REPO_DETAILS_FILE.tmp" ] && [ -s "$REPO_DETAILS_FILE.tmp" ]; then
    # File exists and has content
    jq -s '.' "$REPO_DETAILS_FILE.tmp" > "$REPO_DETAILS_FILE"
    rm "$REPO_DETAILS_FILE.tmp"
else
    # No repos found in any project, keep empty array
    echo "[]" > "$REPO_DETAILS_FILE"
    [ -f "$REPO_DETAILS_FILE.tmp" ] && rm "$REPO_DETAILS_FILE.tmp"
fi

echo "Total Projects: $project_count" | tee -a "$REPORT_FILE"
echo "Total Repositories: $total_repos" | tee -a "$REPORT_FILE"

# ========================================
# 2. REPOSITORIES OVER 1GB (API-REPORTED SIZE)
# ========================================
write_section "2. Repositories Over 1GB (API-Reported Size)"

echo "Analyzing repository sizes from Azure DevOps API..." | tee -a "$REPORT_FILE"

large_repos=0
ONE_GB_KB=1048576  # 1GB in kilobytes (Azure DevOps API returns size in KB)

if [ -f "$REPO_DETAILS_FILE" ]; then
    large_repos_json=$(jq "[.[] | select(.size != null and (.size | tonumber) > $ONE_GB_KB)]" "$REPO_DETAILS_FILE")
    large_repos=$(echo "$large_repos_json" | jq 'length')
    
    echo "Repositories over 1GB: $large_repos" | tee -a "$REPORT_FILE"
    
    if [ "$large_repos" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Large Repository Details:" | tee -a "$REPORT_FILE"
        echo "$large_repos_json" | jq -r '.[] | "\(.project)/\(.name): \((.size/1024/1024*100|floor)/100)GB"' | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not analyze repository sizes - no data available" | tee -a "$REPORT_FILE"
fi

# ========================================
# 3. LARGEST REPOSITORY (API-REPORTED SIZE)
# ========================================
write_section "3. Largest Repository (API-Reported Size)"

if [ -f "$REPO_DETAILS_FILE" ]; then
    # Check if any repos have size data
    has_size=$(jq 'any(.size != null)' "$REPO_DETAILS_FILE")
    if [ "$has_size" = "true" ]; then
        # Size is in KB, so divide by 1024 to get MB
        largest_repo=$(jq -r 'max_by(.size // 0) | "\(.project)/\(.name): \((.size/1024*100|floor)/100)MB"' "$REPO_DETAILS_FILE")
        echo "Largest Repository: $largest_repo" | tee -a "$REPORT_FILE"
    else
        echo "No repository size data available" | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not determine largest repository" | tee -a "$REPORT_FILE"
fi

# ========================================
# 4. OLDEST REPOSITORY
# ========================================
write_section "4. Oldest Repository"

echo "Finding oldest repository (by first commit date)..." | tee -a "$REPORT_FILE"

oldest_date=""
oldest_repo=""
oldest_commit=""

# Clear any existing oldest_commits.txt file
rm -f "$TEMP_DATA_DIR/oldest_commits.txt"

if [ -f "$REPO_DETAILS_FILE" ]; then
    # Check if file has valid content (more than just [])
    repo_count_check=$(jq 'length' "$REPO_DETAILS_FILE" 2>/dev/null || echo "0")
    if [ "$repo_count_check" -gt 0 ]; then
        # Use process substitution instead of pipe to avoid subshell issues
        while read -r repo; do
            project=$(echo "$repo" | jq -r '.project')
            repo_name=$(echo "$repo" | jq -r '.name')
            repo_id=$(echo "$repo" | jq -r '.id')
        
        echo "Checking commits for $project/$repo_name..." | tee -a "$REPORT_FILE"
        
        # URL encode project name
        project_encoded=$(url_encode "$project")
        
        # Get oldest commit (order by date ascending, take first)
        # Add error handling to prevent script from exiting on API failures
        # URL encode $ as %24 to prevent curl errors
        commit_data=$(call_api "$ORG_URL/$project_encoded/_apis/git/repositories/$repo_id/commits?%24top=1&%24orderby=committer/date%20asc&api-version=$API_VERSION")
        
        # Validate JSON before processing
        if [ "$commit_data" = "API_ERROR" ] || ! echo "$commit_data" | jq empty 2>/dev/null; then
            echo "  WARNING: Invalid API response for $project/$repo_name (skipping)" | tee -a "$REPORT_FILE"
            continue
        fi
        
        commit_count=$(echo "$commit_data" | jq -r '.count // 0' 2>/dev/null || echo "0")
        
        if [ "$commit_count" -gt 0 ]; then
            commit_date=$(echo "$commit_data" | jq -r '.value[0].committer.date' 2>/dev/null || echo "")
            commit_id=$(echo "$commit_data" | jq -r '.value[0].commitId' 2>/dev/null || echo "")
            
            if [ -n "$commit_date" ] && [ "$commit_date" != "null" ]; then
                # Use tab as delimiter to avoid conflicts with special characters in names
                printf '%s\t%s\t%s\n' "$commit_date" "$project/$repo_name" "$commit_id" >> "$TEMP_DATA_DIR/oldest_commits.txt"
            else
                echo "  No valid commit date found for $project/$repo_name" | tee -a "$REPORT_FILE"
            fi
        else
            echo "  No commits found in $project/$repo_name" | tee -a "$REPORT_FILE"
        fi
    done < <(jq -c '.[]' "$REPO_DETAILS_FILE")
    
    if [ -f "$TEMP_DATA_DIR/oldest_commits.txt" ] && [ -s "$TEMP_DATA_DIR/oldest_commits.txt" ]; then
        # Sort by first field (date) explicitly using tab as separator
        oldest_line=$(LC_ALL=C sort -t$'\t' -k1,1 "$TEMP_DATA_DIR/oldest_commits.txt" | head -n 1)
        oldest_date=$(echo "$oldest_line" | cut -f1)
        oldest_repo=$(echo "$oldest_line" | cut -f2)
        oldest_commit=$(echo "$oldest_line" | cut -f3)
        
        echo "Oldest Repository: $oldest_repo" | tee -a "$REPORT_FILE"
        echo "First Commit Date: $oldest_date" | tee -a "$REPORT_FILE"
        echo "Commit ID: $oldest_commit" | tee -a "$REPORT_FILE"
    else
        echo "No commit history found" | tee -a "$REPORT_FILE"
    fi
    else
        echo "No repositories with valid data found" | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not determine oldest repository" | tee -a "$REPORT_FILE"
fi

# ========================================
# 5. LARGE FILES SCAN (INDIVIDUAL FILE SIZES)
# ========================================
write_section "5. Large Files Scan (Individual File Sizes)"

# Check if Git is available and user opted in for scanning
if [ "$SCAN_LARGE_FILES" = "1" ] && command -v git &> /dev/null; then
    # Refresh token before long-running operation (cloning can take time)
    refresh_token
    
    echo "Scanning repositories for large files (>50MB)..." | tee -a "$REPORT_FILE"
    echo "This will clone repositories and may take some time..." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Size threshold: 50MB in bytes
    LARGE_FILE_THRESHOLD_BYTES=52428800  # 50MB
    total_large_files=0
    repos_with_large_files=0
    
    # Create temp file for large files (use absolute path)
    LARGE_FILES_LIST="$PWD/$TEMP_DATA_DIR/large_files.txt"
    > "$LARGE_FILES_LIST"
    
    # Save original directory
    ORIGINAL_DIR="$PWD"
    
    if [ -f "$REPO_DETAILS_FILE" ]; then
        while read -r repo; do
            project=$(echo "$repo" | jq -r '.project')
            repo_name=$(echo "$repo" | jq -r '.name')
            
            [ "$DEBUG" = "1" ] && echo "  Scanning $project/$repo_name..." | tee -a "$REPORT_FILE"
            
            # URL encode project name for clone URL
            project_encoded=$(url_encode "$project")
            
            # Create temp directory for this repo
            repo_temp_dir="$ORIGINAL_DIR/$TEMP_DATA_DIR/scan_${repo_name}_$$"
            mkdir -p "$repo_temp_dir"
            cd "$repo_temp_dir"
            
            # Clone as bare repository (faster, includes all history)
            # Use Azure AD Bearer token with http.extraHeader for authentication, securely via a temporary file
            header_file="$repo_temp_dir/git_header.txt"
            echo "Authorization: Bearer $ADO_TOKEN" > "$header_file"
            chmod 600 "$header_file"
            git -c http.extraHeader=@"$header_file" clone --bare --quiet "https://dev.azure.com/$ORG/$project_encoded/_git/$repo_name" repo.git 2>/dev/null
            rm -f "$header_file"
            
            if [ $? -eq 0 ] && [ -d "repo.git" ]; then
                cd repo.git
                
                # Find all large blobs in Git history
                large_blobs=$(git rev-list --objects --all | \
                    git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | \
                    awk -v threshold=$LARGE_FILE_THRESHOLD_BYTES '$1 == "blob" && $3 > threshold {printf "%.2f|%s\n", $3/1024/1024, $4}' | \
                    sort -t'|' -k1 -rn)
                
                if [ -n "$large_blobs" ]; then
                    file_count=$(echo "$large_blobs" | wc -l | tr -d ' ')
                    repos_with_large_files=$((repos_with_large_files + 1))
                    total_large_files=$((total_large_files + file_count))
                    
                    echo "    Found $file_count large file(s):" | tee -a "$REPORT_FILE"
                    echo "$large_blobs" | while IFS='|' read -r size_mb path; do
                        echo "      - $path (${size_mb}MB)" | tee -a "$REPORT_FILE"
                        echo "$project/$repo_name|$path|${size_mb}MB" >> "$LARGE_FILES_LIST"
                    done
                else
                    echo "    No large files found" | tee -a "$REPORT_FILE"
                fi
                
                cd "$ORIGINAL_DIR" > /dev/null
            else
                echo "    WARNING: Failed to clone repository" | tee -a "$REPORT_FILE"
            fi
            
            # Cleanup this repo's temp directory
            cd "$ORIGINAL_DIR" > /dev/null
            rm -rf "$repo_temp_dir"
            
        done < <(jq -c '.[]' "$REPO_DETAILS_FILE")
    fi
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Total Large Files (>50MB): $total_large_files" | tee -a "$REPORT_FILE"
    echo "Repositories with Large Files: $repos_with_large_files" | tee -a "$REPORT_FILE"
    
    if [ "$total_large_files" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "NOTE: GitHub warns about files >50MB and blocks files >100MB." | tee -a "$REPORT_FILE"
        echo "Consider using Git LFS for these files during migration." | tee -a "$REPORT_FILE"
    fi
    
else
    # Original API limitation message
    if [ "$SCAN_LARGE_FILES" = "1" ] && ! command -v git &> /dev/null; then
        echo "WARNING: SCAN_LARGE_FILES=1 but Git is not installed" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
    fi
    
    echo "NOTE: Azure DevOps API does not provide file size information via REST API." | tee -a "$REPORT_FILE"
    echo "To detect large files (>50MB), run this script with: SCAN_LARGE_FILES=1 ./ado-data-collector.sh" | tee -a "$REPORT_FILE"
    echo "This will clone repositories and scan for large files (requires Git installed)." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Alternative methods:" | tee -a "$REPORT_FILE"
    echo "  1. Clone repositories locally and run: git ls-files -z | xargs -0 du -h | sort -rh | head" | tee -a "$REPORT_FILE"
    echo "  2. Use Azure Repos web interface to browse repository contents" | tee -a "$REPORT_FILE"
    echo "  3. Check if Git LFS is already configured: git lfs ls-files" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "GitHub migration considerations:" | tee -a "$REPORT_FILE"
    echo "  - GitHub warns about files >50MB" | tee -a "$REPORT_FILE"
    echo "  - GitHub blocks files >100MB" | tee -a "$REPORT_FILE"
    echo "  - Consider using Git LFS for binary files and large assets" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Initialize variables for summary
    total_large_files=0
    repos_with_large_files=0
    
    if [ "$large_repos" -gt 0 ]; then
        echo "Repositories over 1GB (likely to contain large files):" | tee -a "$REPORT_FILE"
        echo "$large_repos_json" | jq -r '.[] | "  - \(.project)/\(.name)"' | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "Recommend manual inspection of these repositories for large files." | tee -a "$REPORT_FILE"
    fi
fi

# ========================================
# 6. METADATA DATA
# ========================================
write_section "6. Metadata Data"

echo "Checking for work items, pull requests, and boards..." | tee -a "$REPORT_FILE"

total_work_items=0
total_pull_requests=0
projects_with_boards=0

for project in "${projects[@]}"; do
    [ "$DEBUG" = "1" ] && echo "  Checking metadata for project: $project" | tee -a "$REPORT_FILE"
    
    # URL encode project name
    project_encoded=$(url_encode "$project")
    
    # Check for work items using POST request
    wi_response=$(call_api_post "$ORG_URL/$project_encoded/_apis/wit/wiql?api-version=$API_VERSION" '{"query": "Select [System.Id] From WorkItems"}')
    work_items=$(safe_jq_count "$wi_response" '.workItems | length')
    
    total_work_items=$((total_work_items + work_items))
    
    # Check for pull requests
    if [ -f "$REPO_DETAILS_FILE" ]; then
        # Use while-read loop to safely handle repo IDs (Bash 3.2 compatible), use jq --arg for safe string passing
        project_repos=()
        while IFS= read -r repo_id; do
            [ -n "$repo_id" ] && project_repos+=("$repo_id")
        done < <(jq -r --arg proj "$project" '.[] | select(.project == $proj) | .id' "$REPO_DETAILS_FILE")
        
        # Only loop if we actually have repo IDs (skip empty array)
        if [ ${#project_repos[@]} -gt 0 ] && [ -n "${project_repos[0]}" ]; then
            for repo_id in "${project_repos[@]}"; do
                pr_response=$(call_api "$ORG_URL/$project_encoded/_apis/git/repositories/$repo_id/pullrequests?api-version=$API_VERSION")
                pr_count=$(safe_jq_count "$pr_response" '.count')
                total_pull_requests=$((total_pull_requests + pr_count))
            done
        fi
    fi
    
    # Check for boards (teams indicate board usage)
    teams_response=$(call_api "$ORG_URL/_apis/projects/$project_encoded/teams?api-version=$API_VERSION")
    teams=$(safe_jq_count "$teams_response" '.count')
    if [ "$teams" -gt 0 ]; then
        projects_with_boards=$((projects_with_boards + 1))
    fi
done

echo "Total Work Items: $total_work_items" | tee -a "$REPORT_FILE"
echo "Total Pull Requests: $total_pull_requests" | tee -a "$REPORT_FILE"
echo "Projects with Boards/Teams: $projects_with_boards" | tee -a "$REPORT_FILE"

# ========================================
# 7. PIPELINE DATA
# ========================================
write_section "7. Pipeline Data"

echo "Checking for existing pipelines..." | tee -a "$REPORT_FILE"

total_pipelines=0
repos_with_pipelines=0

for project in "${projects[@]}"; do
    [ "$DEBUG" = "1" ] && echo "  Checking pipelines for project: $project" | tee -a "$REPORT_FILE"
    
    # URL encode project name
    project_encoded=$(url_encode "$project")
    
    # Get build definitions (pipelines)
    pipeline_response=$(call_api "$ORG_URL/$project_encoded/_apis/build/definitions?api-version=$API_VERSION")
    pipelines=$(safe_jq_count "$pipeline_response" '.count')
    
    if [ "$pipelines" -gt 0 ]; then
        total_pipelines=$((total_pipelines + pipelines))
        
        # Get details about which repos have pipelines (reuse existing response)
        if [ "$pipeline_response" != "API_ERROR" ] && echo "$pipeline_response" | jq empty 2>/dev/null; then
            repo_count=$(echo "$pipeline_response" | jq '[.value[].repository.id] | unique | length' 2>/dev/null || echo "0")
            repos_with_pipelines=$((repos_with_pipelines + repo_count))
        fi
    fi
done

echo "Total Pipelines: $total_pipelines" | tee -a "$REPORT_FILE"
echo "Repositories with Pipelines: $repos_with_pipelines" | tee -a "$REPORT_FILE"

# ========================================
# 8. SECURITY SCANNING (ADVANCED SECURITY)
# ========================================
write_section "8. Security Scanning (Advanced Security)"

echo "Checking for Azure DevOps Advanced Security alerts..." | tee -a "$REPORT_FILE"

# Note: Advanced Security is a paid add-on feature in Azure DevOps
# API: https://advsec.dev.azure.com/{org}/_apis/...
# Uses the same Azure AD Bearer token for authentication

total_secret_alerts=0
total_dependency_alerts=0
total_code_alerts=0
repos_with_alerts=0

# Check if Advanced Security is enabled by testing the API
# Note: Using call_api with Bearer token (same auth as all other APIs)
advsec_test=$(call_api "https://advsec.dev.azure.com/$ORG/_apis/management/enablement?api-version=7.2-preview.1")

if [ "$advsec_test" != "API_ERROR" ] && echo "$advsec_test" | jq empty 2>/dev/null; then
    echo "Advanced Security is enabled for this organization" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Iterate through all projects and their repositories
    for project in "${projects[@]}"; do
        [ "$DEBUG" = "1" ] && echo "  Checking Advanced Security for project: $project" | tee -a "$REPORT_FILE"
        
        # URL encode project name
        project_encoded=$(url_encode "$project")
        
        # Get repositories for this project from the cached repo details
        if [ -f "$REPO_DETAILS_FILE" ]; then
            while IFS= read -r repo_line; do
                repo_name=$(echo "$repo_line" | jq -r '.name')
                repo_id=$(echo "$repo_line" | jq -r '.id')
                
                [ -z "$repo_id" ] || [ "$repo_id" = "null" ] && continue
                
                echo "    Checking repo: $repo_name ($repo_id)" | tee -a "$REPORT_FILE"
                
                # Query each alert type separately using criteria.alertType filter
                # alertType values: 1=dependency, 2=secret, 3=code
                # criteria.states=1 means active alerts only
                # 
                # Note on confidence levels:
                # - Secret alerts (type 2) use confidence levels (High, Medium, Low, Other) because they use ML-based detection
                # - Dependency alerts (type 1) don't use confidence levels; they're based on CVE databases (deterministic)
                # - Code alerts (type 3) use severity levels, not confidence levels
                
                # Secret alerts (alertType=2) - include all confidence levels for comprehensive results
                secret_alerts=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/alert/repositories/$repo_id/alerts?criteria.alertType=2&criteria.states=1&criteria.confidenceLevels=High&criteria.confidenceLevels=Medium&criteria.confidenceLevels=Low&criteria.confidenceLevels=Other&api-version=7.2-preview.1")
                if [ "$secret_alerts" != "API_ERROR" ] && echo "$secret_alerts" | jq empty 2>/dev/null; then
                    secret_count=$(echo "$secret_alerts" | jq '.count // 0' 2>/dev/null || echo "0")
                    [ "$DEBUG" = "1" ] && echo "[DEBUG] Secret alerts response: $secret_alerts" >&2
                else
                    secret_count=0
                fi
                
                # Dependency alerts (alertType=1)
                dependency_alerts=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/alert/repositories/$repo_id/alerts?criteria.alertType=1&criteria.states=1&api-version=7.2-preview.1")
                if [ "$dependency_alerts" != "API_ERROR" ] && echo "$dependency_alerts" | jq empty 2>/dev/null; then
                    dependency_count=$(echo "$dependency_alerts" | jq '.count // 0' 2>/dev/null || echo "0")
                else
                    dependency_count=0
                fi
                
                # Code scanning alerts (alertType=3)
                code_alerts=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/alert/repositories/$repo_id/alerts?criteria.alertType=3&criteria.states=1&api-version=7.2-preview.1")
                if [ "$code_alerts" != "API_ERROR" ] && echo "$code_alerts" | jq empty 2>/dev/null; then
                    code_count=$(echo "$code_alerts" | jq '.count // 0' 2>/dev/null || echo "0")
                else
                    code_count=0
                fi
                
                total_secret_alerts=$((total_secret_alerts + secret_count))
                total_dependency_alerts=$((total_dependency_alerts + dependency_count))
                total_code_alerts=$((total_code_alerts + code_count))
                
                if [ "$secret_count" -gt 0 ] || [ "$dependency_count" -gt 0 ] || [ "$code_count" -gt 0 ]; then
                    repos_with_alerts=$((repos_with_alerts + 1))
                    echo "      Found: $secret_count secret, $dependency_count dependency, $code_count code alerts" | tee -a "$REPORT_FILE"
                fi
            done < <(jq -c --arg proj "$project" '.[] | select(.project == $proj)' "$REPO_DETAILS_FILE")
        fi
    done
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Total Secret Scanning Alerts: $total_secret_alerts" | tee -a "$REPORT_FILE"
    echo "Total Dependency Scanning Alerts: $total_dependency_alerts" | tee -a "$REPORT_FILE"
    echo "Total Code Scanning Alerts: $total_code_alerts" | tee -a "$REPORT_FILE"
    echo "Repositories with Security Alerts: $repos_with_alerts" | tee -a "$REPORT_FILE"
else
    echo "Advanced Security is NOT enabled for this organization" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "NOTE: Azure DevOps Advanced Security is a paid add-on feature that includes:" | tee -a "$REPORT_FILE"
    echo "  - Secret scanning (credentials, tokens, keys)" | tee -a "$REPORT_FILE"
    echo "  - Dependency scanning (vulnerable packages)" | tee -a "$REPORT_FILE"
    echo "  - Code scanning (security vulnerabilities)" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Alternative: Consider using third-party security scanning tools or" | tee -a "$REPORT_FILE"
    echo "GitHub Advanced Security after migration." | tee -a "$REPORT_FILE"
fi

# ========================================
# 9. CUSTOM INTEGRATIONS
# ========================================
write_section "9. Custom Integrations (Service Hooks)"

echo "Checking for service hooks and integrations..." | tee -a "$REPORT_FILE"

total_hooks=0
hook_types=()

for project in "${projects[@]}"; do
    [ "$DEBUG" = "1" ] && echo "  Checking service hooks for project: $project" | tee -a "$REPORT_FILE"
    
    # URL encode project name
    project_encoded=$(url_encode "$project")
    
    # Get service hooks
    hooks=$(call_api "$ORG_URL/$project_encoded/_apis/hooks/subscriptions?api-version=$API_VERSION")
    hook_count=$(safe_jq_count "$hooks" '.count')
    
    if [ "$hook_count" -gt 0 ]; then
        total_hooks=$((total_hooks + hook_count))
        
        # Collect hook types (only if valid JSON)
        if [ "$hooks" != "API_ERROR" ] && echo "$hooks" | jq empty 2>/dev/null; then
            echo "$hooks" | jq -r '.value[].consumerType' 2>/dev/null >> "$TEMP_DATA_DIR/hook_types.txt"
        fi
    fi
done

echo "Total Service Hooks: $total_hooks" | tee -a "$REPORT_FILE"

if [ -f "$TEMP_DATA_DIR/hook_types.txt" ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "Integration Types Found:" | tee -a "$REPORT_FILE"
    # Process file directly to avoid subshell and properly handle spaces
    sort "$TEMP_DATA_DIR/hook_types.txt" | uniq | while read -r hook; do
        echo "  - $hook" | tee -a "$REPORT_FILE"
    done
fi

# ========================================
# 10. USER DATA
# ========================================
write_section "10. User Data"

echo "Collecting user information..." | tee -a "$REPORT_FILE"

# Get organization users (requires vsaex subdomain)
users=$(call_api "https://vsaex.dev.azure.com/$ORG/_apis/userentitlements?api-version=$API_VERSION")
user_count=$(safe_jq_count "$users" '.totalCount')

echo "Total Users in Organization: $user_count" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Get user access levels
if [ "$user_count" -gt 0 ] && [ "$users" != "API_ERROR" ] && echo "$users" | jq empty 2>/dev/null; then
    echo "User Access Level Breakdown:" | tee -a "$REPORT_FILE"
    echo "$users" | jq -r '.items[].accessLevel.accountLicenseType' 2>/dev/null | sort | uniq -c | while read -r count level; do
        echo "  - $level: $count users" | tee -a "$REPORT_FILE"
    done
    
    # Export user list to CSV
    USER_CSV="$TEMP_DATA_DIR/users.csv"
    echo "displayName,emailAddress,accessLevel,lastAccessDate" > "$USER_CSV"
    # Use jq @csv to properly escape fields with commas, quotes, and newlines
    echo "$users" | jq -r '.items[] | [.user.displayName, .user.mailAddress, .accessLevel.accountLicenseType, .lastAccessedDate] | @csv' 2>/dev/null >> "$USER_CSV"
    echo "" | tee -a "$REPORT_FILE"
    echo "User details exported to: $USER_CSV" | tee -a "$REPORT_FILE"
fi

# ========================================
# SUMMARY
# ========================================
write_section "Migration Data Summary"

echo "Total Projects: $project_count" | tee -a "$REPORT_FILE"
echo "Total Repositories: $total_repos" | tee -a "$REPORT_FILE"
echo "Large Repositories (>1GB): $large_repos" | tee -a "$REPORT_FILE"
echo "Large Files (>50MB): $total_large_files" | tee -a "$REPORT_FILE"
echo "Repositories with Large Files: $repos_with_large_files" | tee -a "$REPORT_FILE"
echo "Total Pipelines: $total_pipelines" | tee -a "$REPORT_FILE"
echo "Repositories with Pipelines: $repos_with_pipelines" | tee -a "$REPORT_FILE"
echo "Total Secret Scanning Alerts: $total_secret_alerts" | tee -a "$REPORT_FILE"
echo "Total Dependency Scanning Alerts: $total_dependency_alerts" | tee -a "$REPORT_FILE"
echo "Total Code Scanning Alerts: $total_code_alerts" | tee -a "$REPORT_FILE"
echo "Repositories with Security Alerts: $repos_with_alerts" | tee -a "$REPORT_FILE"
echo "Total Users: $user_count" | tee -a "$REPORT_FILE"
echo "Total Service Hooks: $total_hooks" | tee -a "$REPORT_FILE"
echo "Total Work Items: $total_work_items" | tee -a "$REPORT_FILE"
echo "Total Pull Requests: $total_pull_requests" | tee -a "$REPORT_FILE"
echo "Projects with Boards/Teams: $projects_with_boards" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"
echo "Report generation complete!" | tee -a "$REPORT_FILE"
echo "Report saved to: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"

# Temp directory will be automatically cleaned up by trap on exit
