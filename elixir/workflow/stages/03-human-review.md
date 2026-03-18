## Step 4: Share Evidence

SYMPHONY_PHASE: Share Evidence

Post test results — including screenshots — to the Linear issue.

### Upload screenshots to Linear

For each screenshot file, upload it and get an asset URL:

```bash
ASSET_URL=$(workflow/scripts/linear-upload-screenshot.sh screenshot.png)
```

Or use the inline approach:
```bash
# Step 1: Get upload URL
UPLOAD_RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { fileUpload(contentType: \"image/png\", filename: \"screenshot.png\", size: 0) { success uploadFile { uploadUrl assetUrl } } }"}')

UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")

# Step 2: Upload the file
curl -s -X PUT "$UPLOAD_URL" \
  -H "Content-Type: image/png" \
  -H "Cache-Control: public, max-age=31536000" \
  --data-binary @screenshot.png
```

### Post test results comment

Post a comment with test summary and embedded screenshots:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: Bearer $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }",
    "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\nSummary of what was tested.\n\n![Screenshot description](ASSET_URL_HERE)"}
  }'
```

Or use the Linear MCP tools to post the comment.
