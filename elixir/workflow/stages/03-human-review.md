## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

### Prepare the browser environment

1. Source the slot info and read the project's CLAUDE.md for test credentials:
   ```bash
   source .symphony_slot
   cd $DIRECTORY
   ```

2. Clear stale Vite state and restart the frontend:
   ```bash
   cd frontend && rm -rf node_modules/.vite
   pkill -f "vite.*$FRONTEND_PORT" 2>/dev/null
   cd $DIRECTORY && ~/.claude/scripts/devenv-start.sh
   ```

3. Wait for the frontend to respond:
   ```bash
   until curl -s -o /dev/null -w "%{http_code}" http://localhost:$FRONTEND_PORT | grep -q 200; do sleep 2; done
   ```

### Take screenshots with Playwright via bash

Do NOT use the Playwright MCP tools — use Playwright directly via bash scripts. This is faster and uses less context.

Write a short Node.js script and run it:

```bash
cat > /tmp/screenshot-test.js << 'SCRIPT'
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  // Navigate to the app
  await page.goto(process.env.APP_URL || 'http://localhost:5213');
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: '/tmp/screenshot-landing.png', fullPage: true });

  // Log in (adjust selectors for your app)
  // await page.fill('input[name="email"]', 'test+dispatcher@gearflow.com');
  // await page.fill('input[name="password"]', 'gearflow2025');
  // await page.click('button[type="submit"]');
  // await page.waitForLoadState('networkidle');

  // Navigate to the relevant page and screenshot
  // await page.goto(process.env.APP_URL + '/path/to/feature');
  // await page.screenshot({ path: '/tmp/screenshot-feature.png', fullPage: true });

  await browser.close();
  console.log('Screenshots saved to /tmp/screenshot-*.png');
})();
SCRIPT

APP_URL="http://localhost:$FRONTEND_PORT" node /tmp/screenshot-test.js
```

Adapt the script for your specific changes:
- Log in with test credentials from CLAUDE.md
- Navigate to the pages affected by your changes
- Take before/after screenshots at key states
- Name screenshots descriptively

### If the browser or dev server is broken

1. **Clear Vite cache and restart** (see above).
2. **If still broken**: Use `SYMPHONY_NEEDS_HELP: Browser testing blocked — <describe the error>` and STOP. Do not post evidence without screenshots.

### Post evidence to Linear

Post a single comment on the Linear issue that includes:
- What you tested and how (specific pages, flows)
- Test results (unit tests passing, browser verification)
- Screenshots embedded as images

To upload a screenshot and post it:
```bash
# Upload screenshot to Linear
FILESIZE=$(wc -c < /tmp/screenshot-landing.png | tr -d ' ')
UPLOAD=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { fileUpload(contentType: \\\"image/png\\\", filename: \\\"screenshot.png\\\", size: $FILESIZE) { success uploadFile { uploadUrl assetUrl headers { key value } } } }\"}")

UPLOAD_URL=$(echo "$UPLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")
HEADERS=$(echo "$UPLOAD" | python3 -c "
import sys,json
for h in json.load(sys.stdin)['data']['fileUpload']['uploadFile']['headers']:
    print(f'-H \"{h[\"key\"]}: {h[\"value\"]}\"')
")

eval curl -s -X PUT "\"$UPLOAD_URL\"" \
  -H "\"Content-Type: image/png\"" \
  -H "\"Cache-Control: public, max-age=31536000\"" \
  $HEADERS \
  --data-binary @/tmp/screenshot-landing.png
```

Then post the comment with the asset URL using Linear MCP `save_comment` or curl:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\n**Unit tests**: All passing\n**Browser verification**: Confirmed\n\n![screenshot]('"$ASSET_URL"')"}}'
```

Post to **Linear**, not GitHub.

### Done

You have completed the Share Evidence phase. Stop here.
Your deliverable is the Linear comment with test results AND browser screenshots.
