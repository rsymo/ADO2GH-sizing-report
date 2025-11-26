#!/bin/bash

# ========================================
# Azure DevOps Migration Scoping Report
# ========================================
# This script generates a comprehensive migration scoping report
# for Azure DevOps to GitHub migrations.

set -e

# -------- CONFIGURATION --------
ORG="your-org-name"
PAT="your-personal-access-token"
ORG_URL="https://dev.azure.com/$ORG"

# Report output file
REPORT_FILE="migration-scoping-report-$(date +%Y%m%d-%H%M%S).txt"
TEMP_DATA_DIR="temp_migration_data"
mkdir -p "$TEMP_DATA_DIR"

# API version
API_VERSION="7.1-preview.1"

# -------- HELPER FUNCTIONS --------

# Function to make Azure DevOps API calls (GET requests)
call_api() {
    local endpoint="$1"
    # Use -f to fail on HTTP errors, but capture output
    # Use -L to follow redirects
    curl -s -S -f -L -u ":$PAT" "$endpoint" || echo "API_ERROR"
}

# Function to make Azure DevOps API POST calls
call_api_post() {
    local endpoint="$1"
    local data="$2"
    curl -s -S -f -L -u ":$PAT" -H "Content-Type: application/json" -X POST -d "$data" "$endpoint" || echo "API_ERROR"
}

# Function to safely extract a numeric value from JSON.
# Returns 0 if the API call fails (input is "API_ERROR"), JSON is invalid, or the path doesn't exist.
safe_jq_count() {
    local json="$1"
    local path="$2"
    if [ "$json" == "API_ERROR" ] || ! echo "$json" | jq empty 2>/dev/null; then
        echo "0"
    else
        echo "$json" | jq -r "$path // 0" 2>/dev/null || echo "0"
    fi
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
echo "Generating Azure DevOps Migration Scoping Report..." | tee "$REPORT_FILE"
echo "Organization: $ORG" | tee -a "$REPORT_FILE"
echo "Generated: $(date)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# ========================================
# 1. REPOSITORY COUNT
# ========================================
write_section "1. Repository Count"

echo "Collecting repository data..." | tee -a "$REPORT_FILE"

# Get all projects
projects_response=$(call_api "$ORG_URL/_apis/projects?api-version=$API_VERSION")

# Validate JSON response
if [ "$projects_response" == "API_ERROR" ] || ! echo "$projects_response" | jq empty 2>/dev/null; then
    echo "ERROR: Failed to retrieve projects from Azure DevOps API" | tee -a "$REPORT_FILE"
    echo "Response: $projects_response" | tee -a "$REPORT_FILE"
    exit 1
fi

projects=$(echo "$projects_response" | jq -r '.value[].name')
total_repos=0
project_count=0

# Create temporary file for repo details
REPO_DETAILS_FILE="$TEMP_DATA_DIR/repo_details.json"
echo "[]" > "$REPO_DETAILS_FILE"

for project in $projects; do
    project_count=$((project_count + 1))
    
    # Get repos for this project
    repos_json=$(call_api "$ORG_URL/$project/_apis/git/repositories?api-version=$API_VERSION")
    
    # Validate JSON response before processing
    if [ "$repos_json" == "API_ERROR" ] || ! echo "$repos_json" | jq empty 2>/dev/null; then
        echo "WARNING: Failed to retrieve repositories for project '$project' (skipping)" | tee -a "$REPORT_FILE"
        continue
    fi
    
    repo_count=$(echo "$repos_json" | jq -r '.value | length')
    total_repos=$((total_repos + repo_count))
    
    # Store repo details for later analysis
    echo "$repos_json" | jq -c ".value[] | {project: \"$project\", name: .name, id: .id, size: .size, defaultBranch: .defaultBranch, remoteUrl: .remoteUrl}" >> "$REPO_DETAILS_FILE.tmp"
done

# Consolidate all repo details into a single JSON array
if [ -f "$REPO_DETAILS_FILE.tmp" ]; then
    jq -s '.' "$REPO_DETAILS_FILE.tmp" > "$REPO_DETAILS_FILE"
    rm "$REPO_DETAILS_FILE.tmp"
fi

echo "Total Projects: $project_count" | tee -a "$REPORT_FILE"
echo "Total Repositories: $total_repos" | tee -a "$REPORT_FILE"

# ========================================
# 2. REPOSITORIES OVER 1GB
# ========================================
write_section "2. Repositories Over 1GB"

echo "Analyzing repository sizes..." | tee -a "$REPORT_FILE"

large_repos=0
ONE_GB=1073741824  # 1GB in bytes

if [ -f "$REPO_DETAILS_FILE" ]; then
    large_repos_json=$(jq "[.[] | select(.size != null and (.size | tonumber) > $ONE_GB)]" "$REPO_DETAILS_FILE")
    large_repos=$(echo "$large_repos_json" | jq 'length')
    
    echo "Repositories over 1GB: $large_repos" | tee -a "$REPORT_FILE"
    
    if [ "$large_repos" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Large Repository Details:" | tee -a "$REPORT_FILE"
        echo "$large_repos_json" | jq -r '.[] | "\(.project)/\(.name): \((.size/1024/1024/1024*100|floor)/100)GB"' | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not analyze repository sizes - no data available" | tee -a "$REPORT_FILE"
fi

# ========================================
# 3. LARGEST REPOSITORY
# ========================================
write_section "3. Largest Repository"

if [ -f "$REPO_DETAILS_FILE" ]; then
    largest_repo=$(jq -r 'max_by(.size // 0) | "\(.project)/\(.name): \((.size/1024/1024/1024*100|floor)/100)GB"' "$REPO_DETAILS_FILE")
    echo "Largest Repository: $largest_repo" | tee -a "$REPORT_FILE"
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
    # Use process substitution instead of pipe to avoid subshell issues
    while read -r repo; do
        project=$(echo "$repo" | jq -r '.project')
        repo_name=$(echo "$repo" | jq -r '.name')
        repo_id=$(echo "$repo" | jq -r '.id')
        
        echo "Checking commits for $project/$repo_name..." | tee -a "$REPORT_FILE"
        
        # Get oldest commit (order by date ascending, take first)
        # Add error handling to prevent script from exiting on API failures
        commit_data=$(call_api "$ORG_URL/$project/_apis/git/repositories/$repo_id/commits?\$top=1&\$orderby=committer/date asc&api-version=$API_VERSION")
        
        # Validate JSON before processing
        if [ "$commit_data" == "API_ERROR" ] || ! echo "$commit_data" | jq empty 2>/dev/null; then
            echo "  WARNING: Invalid API response for $project/$repo_name (skipping)" | tee -a "$REPORT_FILE"
            continue
        fi
        
        commit_count=$(echo "$commit_data" | jq -r '.count // 0' 2>/dev/null || echo "0")
        
        if [ "$commit_count" -gt 0 ]; then
            commit_date=$(echo "$commit_data" | jq -r '.value[0].committer.date' 2>/dev/null || echo "")
            commit_id=$(echo "$commit_data" | jq -r '.value[0].commitId' 2>/dev/null || echo "")
            
            if [ -n "$commit_date" ] && [ "$commit_date" != "null" ]; then
                echo "$commit_date|$project/$repo_name|$commit_id" >> "$TEMP_DATA_DIR/oldest_commits.txt"
            else
                echo "  No valid commit date found for $project/$repo_name" | tee -a "$REPORT_FILE"
            fi
        else
            echo "  No commits found in $project/$repo_name" | tee -a "$REPORT_FILE"
        fi
    done < <(jq -c '.[]' "$REPO_DETAILS_FILE")
    
    if [ -f "$TEMP_DATA_DIR/oldest_commits.txt" ]; then
        oldest_line=$(sort "$TEMP_DATA_DIR/oldest_commits.txt" | head -n 1)
        oldest_date=$(echo "$oldest_line" | cut -d'|' -f1)
        oldest_repo=$(echo "$oldest_line" | cut -d'|' -f2)
        oldest_commit=$(echo "$oldest_line" | cut -d'|' -f3)
        
        echo "Oldest Repository: $oldest_repo" | tee -a "$REPORT_FILE"
        echo "First Commit Date: $oldest_date" | tee -a "$REPORT_FILE"
        echo "Commit ID: $oldest_commit" | tee -a "$REPORT_FILE"
    else
        echo "No commit history found" | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not determine oldest repository" | tee -a "$REPORT_FILE"
fi

# ========================================
# 5. BINARY/LARGE FILES CHECK
# ========================================
write_section "5. Binary and Large Files"

echo "NOTE: Binary/large file detection requires manual inspection:" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Recommended approaches:" | tee -a "$REPORT_FILE"
echo "1. UI Method: Check each repository's 'Overall reachable repository size'" | tee -a "$REPORT_FILE"
echo "   or 'Size of reachable blobs' in Azure DevOps repository settings." | tee -a "$REPORT_FILE"
echo "   Flag any repositories not showing 'Healthy' status." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "2. Script Method: For suspicious repositories (see large repos above)," | tee -a "$REPORT_FILE"
echo "   clone the repository and run:" | tee -a "$REPORT_FILE"
echo "   git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | sort -k3 -n -r | head -20" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

if [ "$large_repos" -gt 0 ]; then
    echo "RECOMMENDATION: The following repositories are over 1GB and should be checked:" | tee -a "$REPORT_FILE"
    echo "$large_repos_json" | jq -r '.[] | "  - \(.project)/\(.name)"' | tee -a "$REPORT_FILE"
fi

# ========================================
# 6. METADATA MIGRATION NEEDS
# ========================================
write_section "6. Metadata Migration Requirements"

echo "Checking for work items, pull requests, and boards..." | tee -a "$REPORT_FILE"

total_work_items=0
total_pull_requests=0
projects_with_boards=0

for project in $projects; do
    echo "  Checking metadata for project: $project" | tee -a "$REPORT_FILE"
    
    # Check for work items using POST request
    wi_response=$(call_api_post "$ORG_URL/$project/_apis/wit/wiql?api-version=$API_VERSION" '{"query": "Select [System.Id] From WorkItems"}')
    work_items=$(safe_jq_count "$wi_response" '.workItems | length')
    
    total_work_items=$((total_work_items + work_items))
    
    # Check for pull requests
    if [ -f "$REPO_DETAILS_FILE" ]; then
        project_repos=$(jq -r ".[] | select(.project == \"$project\") | .id" "$REPO_DETAILS_FILE")
        
        for repo_id in $project_repos; do
            pr_response=$(call_api "$ORG_URL/$project/_apis/git/repositories/$repo_id/pullrequests?api-version=$API_VERSION")
            pr_count=$(safe_jq_count "$pr_response" '.count')
            total_pull_requests=$((total_pull_requests + pr_count))
        done
    fi
    
    # Check for boards (teams indicate board usage)
    teams_response=$(call_api "$ORG_URL/_apis/projects/$project/teams?api-version=$API_VERSION")
    teams=$(safe_jq_count "$teams_response" '.count')
    if [ "$teams" -gt 0 ]; then
        projects_with_boards=$((projects_with_boards + 1))
    fi
done

echo "Total Work Items: $total_work_items" | tee -a "$REPORT_FILE"
echo "Total Pull Requests: $total_pull_requests" | tee -a "$REPORT_FILE"
echo "Projects with Boards/Teams: $projects_with_boards" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

if [ "$total_work_items" -gt 0 ] || [ "$total_pull_requests" -gt 0 ] || [ "$projects_with_boards" -gt 0 ]; then
    echo "RECOMMENDATION: Metadata migration is recommended" | tee -a "$REPORT_FILE"
    echo "  - Work Items should be considered for migration to GitHub Issues" | tee -a "$REPORT_FILE"
    echo "  - Pull Request history may need to be archived or migrated" | tee -a "$REPORT_FILE"
    echo "  - Board configurations should be replicated in GitHub Projects" | tee -a "$REPORT_FILE"
else
    echo "No significant metadata found - basic migration sufficient" | tee -a "$REPORT_FILE"
fi

# ========================================
# 7. PIPELINE MIGRATION NEEDS
# ========================================
write_section "7. Pipeline Migration Requirements"

echo "Checking for existing pipelines..." | tee -a "$REPORT_FILE"

total_pipelines=0
repos_with_pipelines=0

for project in $projects; do
    echo "  Checking pipelines for project: $project" | tee -a "$REPORT_FILE"
    
    # Get build definitions (pipelines)
    pipeline_response=$(call_api "$ORG_URL/$project/_apis/build/definitions?api-version=$API_VERSION")
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
echo "" | tee -a "$REPORT_FILE"

if [ "$total_pipelines" -gt 0 ]; then
    echo "RECOMMENDATION: Pipeline migration is required" | tee -a "$REPORT_FILE"
    echo "  - Azure Pipelines YAML files should be converted to GitHub Actions" | tee -a "$REPORT_FILE"
    echo "  - Review pipeline triggers and scheduled runs" | tee -a "$REPORT_FILE"
    echo "  - Verify service connections and secrets migration" | tee -a "$REPORT_FILE"
else
    echo "No pipelines found - no workflow migration needed" | tee -a "$REPORT_FILE"
fi

# ========================================
# 8. CUSTOM INTEGRATIONS
# ========================================
write_section "8. Custom Integrations (Service Hooks)"

echo "Checking for service hooks and integrations..." | tee -a "$REPORT_FILE"

total_hooks=0
hook_types=()

for project in $projects; do
    echo "  Checking service hooks for project: $project" | tee -a "$REPORT_FILE"
    
    # Get service hooks
    hooks=$(call_api "$ORG_URL/$project/_apis/hooks/subscriptions?api-version=$API_VERSION")
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
    unique_hooks=$(sort "$TEMP_DATA_DIR/hook_types.txt" | uniq)
    echo "" | tee -a "$REPORT_FILE"
    echo "Integration Types Found:" | tee -a "$REPORT_FILE"
    echo "$unique_hooks" | while read -r hook; do
        echo "  - $hook" | tee -a "$REPORT_FILE"
    done
    echo "" | tee -a "$REPORT_FILE"
    echo "RECOMMENDATION: These integrations need to be recreated in GitHub" | tee -a "$REPORT_FILE"
    echo "  - Review each service hook and identify GitHub equivalent (webhooks, apps, or actions)" | tee -a "$REPORT_FILE"
else
    echo "No custom integrations found" | tee -a "$REPORT_FILE"
fi

# ========================================
# 9. USER MIGRATION
# ========================================
write_section "9. User Migration Requirements"

echo "Collecting user information..." | tee -a "$REPORT_FILE"

# Get organization users
users=$(call_api "$ORG_URL/_apis/userentitlements?api-version=$API_VERSION")
user_count=$(safe_jq_count "$users" '.totalCount')

echo "Total Users in Organization: $user_count" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Get user access levels
if [ "$user_count" -gt 0 ] && [ "$users" != "API_ERROR" ] && echo "$users" | jq empty 2>/dev/null; then
    echo "User Access Level Breakdown:" | tee -a "$REPORT_FILE"
    echo "$users" | jq -r '.members[].accessLevel.accountLicenseType' 2>/dev/null | sort | uniq -c | while read -r count level; do
        echo "  - $level: $count users" | tee -a "$REPORT_FILE"
    done
    
    echo "" | tee -a "$REPORT_FILE"
    echo "RECOMMENDATION: Plan user migration and GitHub seat allocation" | tee -a "$REPORT_FILE"
    echo "  - Map Azure DevOps users to GitHub accounts" | tee -a "$REPORT_FILE"
    echo "  - Determine appropriate GitHub team structure" | tee -a "$REPORT_FILE"
    echo "  - Consider GitHub seat licenses needed" | tee -a "$REPORT_FILE"
    
    # Export user list to CSV
    USER_CSV="$TEMP_DATA_DIR/users.csv"
    echo "displayName,emailAddress,accessLevel,lastAccessDate" > "$USER_CSV"
    echo "$users" | jq -r '.members[] | "\(.user.displayName),\(.user.mailAddress),\(.accessLevel.accountLicenseType),\(.lastAccessedDate)"' 2>/dev/null >> "$USER_CSV"
    echo "" | tee -a "$REPORT_FILE"
    echo "User details exported to: $USER_CSV" | tee -a "$REPORT_FILE"
fi

# ========================================
# SUMMARY AND RECOMMENDATIONS
# ========================================
write_section "Migration Scoping Summary"

echo "KEY FINDINGS:" | tee -a "$REPORT_FILE"
echo "  • Repositories to migrate: $total_repos" | tee -a "$REPORT_FILE"
echo "  • Large repositories (>1GB): $large_repos" | tee -a "$REPORT_FILE"
echo "  • Pipelines requiring conversion: $total_pipelines" | tee -a "$REPORT_FILE"
echo "  • Users to migrate: $user_count" | tee -a "$REPORT_FILE"
echo "  • Service hooks/integrations: $total_hooks" | tee -a "$REPORT_FILE"
echo "  • Work items: $total_work_items" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

echo "MIGRATION COMPLEXITY ASSESSMENT:" | tee -a "$REPORT_FILE"
complexity_score=0

if [ "$large_repos" -gt 0 ]; then
    complexity_score=$((complexity_score + 2))
    echo "  ⚠ Large repositories present - will require careful migration planning" | tee -a "$REPORT_FILE"
fi

if [ "$total_pipelines" -gt 10 ]; then
    complexity_score=$((complexity_score + 2))
    echo "  ⚠ Significant pipeline migration required" | tee -a "$REPORT_FILE"
elif [ "$total_pipelines" -gt 0 ]; then
    complexity_score=$((complexity_score + 1))
    echo "  ⚠ Moderate pipeline migration required" | tee -a "$REPORT_FILE"
fi

if [ "$total_hooks" -gt 0 ]; then
    complexity_score=$((complexity_score + 1))
    echo "  ⚠ Custom integrations need recreation" | tee -a "$REPORT_FILE"
fi

if [ "$total_work_items" -gt 100 ]; then
    complexity_score=$((complexity_score + 1))
    echo "  ⚠ Significant metadata migration recommended" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"

if [ "$complexity_score" -le 2 ]; then
    echo "Overall Complexity: LOW - Straightforward migration" | tee -a "$REPORT_FILE"
elif [ "$complexity_score" -le 4 ]; then
    echo "Overall Complexity: MEDIUM - Plan for 2-4 weeks migration window" | tee -a "$REPORT_FILE"
else
    echo "Overall Complexity: HIGH - Plan for 4-8 weeks migration window" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"
echo "Report generation complete!" | tee -a "$REPORT_FILE"
echo "Report saved to: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "Supporting data saved to: $TEMP_DATA_DIR/" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"

# Cleanup option (commented out - uncomment to auto-cleanup)
# rm -rf "$TEMP_DATA_DIR"
