## Step 4: Share Evidence (required — do NOT skip this)

SYMPHONY_PHASE: Share Evidence

You MUST post test results and screenshots to the Linear issue before shipping the PR.

### Upload screenshots to Linear

For each screenshot you captured in Step 3, upload it to Linear:

```bash
# Step 1: Get upload URL from Linear
FILESIZE=$(wc -c < screenshot.png | tr -d ' ')
UPLOAD_RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { fileUpload(contentType: \\\"image/png\\\", filename: \\\"screenshot.png\\\", size: $FILESIZE) { success uploadFile { uploadUrl assetUrl } } }\"}")

UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")

# Step 2: Upload the file
curl -s -X PUT "$UPLOAD_URL" \
  -H "Content-Type: image/png" \
  -H "Cache-Control: public, max-age=31536000" \
  --data-binary @screenshot.png

# Step 3: Use $ASSET_URL in your comment markdown
```

Or use the `workflow/scripts/linear-upload-screenshot.sh` script:
```bash
ASSET_URL=$(workflow/scripts/linear-upload-screenshot.sh screenshot.png)
```

### Post test results comment

Post a comment on the Linear issue with your test summary and embedded screenshots. Use the Linear MCP tools (preferred) or curl:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }",
    "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\n- Unit tests: passing\n- Browser test: verified\n\n![Before fix](ASSET_URL_1)\n![After fix](ASSET_URL_2)"}
  }'
```

**Do NOT proceed to Step 5 (Ship) without posting evidence.**
