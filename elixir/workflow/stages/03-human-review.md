## Step 4: Share Evidence (MANDATORY — do NOT skip)

SYMPHONY_PHASE: Share Evidence

You MUST post test results and browser screenshots to the Linear issue. This is how the team verifies your work.

### Step 4a: Upload each screenshot to Linear

For each screenshot file you saved in Step 3, upload it using this process:

```bash
# Get the file size
FILESIZE=$(wc -c < screenshot.png | tr -d ' ')

# Request upload URL from Linear — note: must also request upload headers
UPLOAD_RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { fileUpload(contentType: \\\"image/png\\\", filename: \\\"screenshot.png\\\", size: $FILESIZE) { success uploadFile { uploadUrl assetUrl headers { key value } } } }\"}")

# Parse the response
UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")

# Build the PUT command with ALL headers from the response (this is required!)
HEADER_ARGS=$(echo "$UPLOAD_RESPONSE" | python3 -c "
import sys,json
data = json.load(sys.stdin)
headers = data['data']['fileUpload']['uploadFile']['headers']
for h in headers:
    print(f'-H \"{h[\"key\"]}: {h[\"value\"]}\"')
")

# Upload the file — include response headers, Content-Type, and Cache-Control
eval curl -s -X PUT \"$UPLOAD_URL\" \
  -H \"Content-Type: image/png\" \
  -H \"Cache-Control: public, max-age=31536000\" \
  $HEADER_ARGS \
  --data-binary @screenshot.png

# Save ASSET_URL for the comment below
echo "Uploaded: $ASSET_URL"
```

Repeat for each screenshot. Collect all ASSET_URLs.

**IMPORTANT:** You MUST include the `headers` field in the `fileUpload` mutation and pass ALL returned headers in the PUT request. Without them the upload silently fails and the image will show "failed to load" in Linear.

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
