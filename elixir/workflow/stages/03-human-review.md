## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

Your ONLY job is: take a screenshot of the app, post it to Linear. Do NOT read source code, do NOT investigate the codebase, do NOT fix anything.

### Step 1: Get your workspace info

```bash
source .symphony_slot
cd $DIRECTORY
```

### Step 2: Take a screenshot

Write this script and run it:

```bash
cat > /tmp/screenshot-test.js << 'SCRIPT'
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const url = process.env.APP_URL;
  await page.goto(url);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: '/tmp/evidence-landing.png', fullPage: true });
  console.log('Screenshot saved: /tmp/evidence-landing.png');
  await browser.close();
})();
SCRIPT
APP_URL="http://localhost:$FRONTEND_PORT" node /tmp/screenshot-test.js
```

If this fails, use `SYMPHONY_NEEDS_HELP: Browser testing blocked` and STOP.

### Step 3: Upload the screenshot and post to Linear

```bash
FILESIZE=$(wc -c < /tmp/evidence-landing.png | tr -d ' ')
UPLOAD=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { fileUpload(contentType: \\\"image/png\\\", filename: \\\"evidence.png\\\", size: $FILESIZE) { success uploadFile { uploadUrl assetUrl headers { key value } } } }\"}")

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
  --data-binary @/tmp/evidence-landing.png

curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "## Test Results\n\n**Browser verification**: App loads and renders correctly.\n\n![evidence]('"$ASSET_URL"')"}}'
```

### Done

Stop here. Do not read source code. Do not investigate. Do not fix anything.
