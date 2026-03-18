## Step 4: Share Evidence (MANDATORY — do NOT skip)

SYMPHONY_PHASE: Share Evidence

You MUST post test results and browser screenshots to the Linear issue. This is how the team verifies your work.

### Step 4a: Upload each screenshot to Linear

For each screenshot file you saved in Step 3, run this sequence:

```bash
# Get the file size
FILESIZE=$(wc -c < screenshot.png | tr -d ' ')

# Request upload URL from Linear
UPLOAD_RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { fileUpload(contentType: \\\"image/png\\\", filename: \\\"screenshot.png\\\", size: $FILESIZE) { success uploadFile { uploadUrl assetUrl } } }\"}")

# Parse the URLs
UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")

# Upload the file
curl -s -X PUT "$UPLOAD_URL" \
  -H "Content-Type: image/png" \
  -H "Cache-Control: public, max-age=31536000" \
  --data-binary @screenshot.png

# Save ASSET_URL — you need it for the comment below
echo "Uploaded: $ASSET_URL"
```

Repeat for each screenshot. Collect all ASSET_URLs.

### Step 4b: Post a test results comment on the Linear issue

Post a single comment that includes:
- What you tested
- Test results (unit tests passing, browser verification)
- Embedded screenshots using the ASSET_URLs from Step 4a

Use the Linear MCP `save_comment` tool (preferred), or curl:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }",
    "variables": {
      "id": "{{ issue.id }}",
      "body": "## Test Results\n\n**Unit tests**: All passing\n**Browser verification**: Confirmed fix works\n\n### Screenshots\n\n![Before](ASSET_URL_1)\n![After](ASSET_URL_2)"
    }
  }'
```

**Do NOT proceed to Step 5 (Ship) without uploading screenshots AND posting the comment.**
