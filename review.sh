#!/bin/bash
set -e

if ! command -v jq &>/dev/null; then
  echo "::error::jq is required but not installed"
  exit 1
fi

COMMENT_MARKER="<!-- pullproof-review -->"
MAX_TOKENS=8000
RETRY_ATTEMPTS=3
RETRY_DELAY=2

if [ -z "$GITHUB_TOKEN" ]; then
  echo "::error::GitHub token is not set"
  exit 1
fi

if [ -z "$OPENAI_API_KEY" ]; then
  echo "::error::OpenAI API key is not set"
  exit 1
fi

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
  echo "::error::PR_NUMBER and REPO env vars are required"
  exit 1
fi

get_review_content() {
  local filename="$1"
  local patch="$2"

  local system_prompt="You are PullProof, an expert technical blog reviewer. Review the following new content added to a blog post and provide structured feedback.

Evaluate these dimensions and give each a rating (Good / Needs Work / Missing):

### Metadata & SEO
- Are title, description, date, author, and tags present?
- Is the title concise and descriptive (under 70 chars)?
- Is the description a good meta summary (under 160 chars)?
- Are tags relevant and specific?

### Technical Accuracy
- Are code examples syntactically correct and runnable?
- Are technical claims accurate?
- Do code blocks have language tags (\`\`\`sql, \`\`\`python, etc.)?
- Are commands/configs complete enough to follow?

### Writing Quality
- Grammar, spelling, punctuation errors?
- Sentence clarity and readability?
- Consistent tone (professional but approachable)?
- Any jargon used without explanation?

### Structure & Flow
- Does it open with a compelling hook or context?
- Do sections follow a logical progression?
- Is there a proper conclusion (not just trailing off)?
- Is the heading hierarchy correct (H2 > H3 > H4)?

### Blog Polish
- Is there a cover image or visual aids where helpful?
- Are references/links provided for claims?
- Is the length appropriate for the topic?
- Any suggestions for diagrams, examples, or visuals?

Format your response as:

### Summary
[1-2 sentence overview of the content and its quality]

### Ratings
| Dimension | Rating | Key Issue |
|-----------|--------|-----------|
| Metadata & SEO | ... | ... |
| Technical Accuracy | ... | ... |
| Writing Quality | ... | ... |
| Structure & Flow | ... | ... |
| Blog Polish | ... | ... |

### Issues Found
[Numbered list of specific issues with line references where possible. Be concrete — quote the problematic text and suggest a fix.]

### Suggestions
[Numbered list of improvements that would make this post better. Focus on high-impact items.]

Be direct. Do not pad with praise. Focus on what needs fixing."

  local escaped_prompt=$(jq -n --arg sys "$system_prompt" --arg file "$filename" --arg content "$patch" \
    '{"role": "system", "content": $sys}, {"role": "user", "content": ("File: " + $file + "\n\nContent to review:\n" + $content)}' |
    jq -s '{model: env.MODEL, messages: ., temperature: 0.3, max_tokens: env.MAX_TOKENS}')

  local attempt=1
  local api_response=""
  while [ $attempt -le $RETRY_ATTEMPTS ]; do
    if [ $attempt -gt 1 ]; then
      echo "Retry attempt $attempt of $RETRY_ATTEMPTS..." >&2
      sleep $RETRY_DELAY
    fi

    # --connect-timeout/--max-time bound each request so a stalled connection
    # can't hang the job (curl's default connect timeout is 300s). -w appends
    # the HTTP status so we can surface the real error instead of swallowing it.
    local raw
    raw=$(curl -s --connect-timeout 10 --max-time 120 -w $'\n%{http_code}' \
      https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -d "$escaped_prompt" || true)

    local http_code
    http_code=$(printf '%s' "$raw" | tail -n1)
    api_response=$(printf '%s' "$raw" | sed '$d')

    if [ "$http_code" = "200" ] && echo "$api_response" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
      break
    fi

    local err_msg
    err_msg=$(echo "$api_response" | jq -r '.error.message // empty' 2>/dev/null)
    echo "::warning::OpenAI request failed (HTTP ${http_code:-000})${err_msg:+: $err_msg}" >&2

    attempt=$((attempt + 1))
  done

  if [ $attempt -gt $RETRY_ATTEMPTS ]; then
    echo "::error::OpenAI API call failed after $RETRY_ATTEMPTS attempts" >&2
    exit 1
  fi

  local review=$(echo "$api_response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$review" ]; then
    echo "::error::No review content received" >&2
    exit 1
  fi

  echo "$review"
}

truncate_content() {
  local content="$1"
  local max_chars=24000

  if [ ${#content} -le $max_chars ]; then
    echo "$content"
    return
  fi

  local truncated=$(echo "$content" | head -c $max_chars)
  local last_newline
  last_newline=$(echo "$truncated" | rev | grep -n '^' | head -1 | cut -d: -f1 2>/dev/null || echo "0")
  if [ -n "$last_newline" ] && [ "$last_newline" != "0" ]; then
    echo "$truncated" | head -c $((max_chars - last_newline))
  else
    echo "$truncated"
  fi
}

echo "Processing PR #$PR_NUMBER"

# Right after a push, GitHub may still be computing the PR diff and return an
# empty `patch` for files that clearly have additions. Retry until the patch is
# populated so we don't silently skip a file whose diff just wasn't ready yet.
FETCH_ATTEMPTS=5
FETCH_DELAY=5
fetch_attempt=1
while :; do
  FILES_RESPONSE=$(curl -sf --connect-timeout 10 --max-time 30 \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$REPO/pulls/$PR_NUMBER/files?per_page=100") || {
    echo "::error::Failed to fetch PR files"
    exit 1
  }

  MD_FILES=$(echo "$FILES_RESPONSE" | jq -c '[.[] | select(.filename | test("\\.(md|mdx)$"))]')
  FILE_COUNT=$(echo "$MD_FILES" | jq 'length')

  if [ "$FILE_COUNT" -eq 0 ] 2>/dev/null || [ "$MD_FILES" = "[]" ]; then
    echo "No .md/.mdx changes found, skipping."
    exit 0
  fi

  PENDING=$(echo "$MD_FILES" | jq '[.[] | select(.additions > 0 and (.patch // "") == "")] | length')
  if [ "$PENDING" -eq 0 ] || [ "$fetch_attempt" -ge "$FETCH_ATTEMPTS" ]; then
    break
  fi

  echo "Diff not ready for $PENDING file(s), retrying ($fetch_attempt/$FETCH_ATTEMPTS)..."
  sleep $FETCH_DELAY
  fetch_attempt=$((fetch_attempt + 1))
done

echo "Found $FILE_COUNT file(s) to review"

TOTAL_REVIEWS=""

for i in $(seq 0 $((FILE_COUNT - 1))); do
  FILE_JSON=$(echo "$MD_FILES" | jq -c ".[$i]")

  FILENAME=$(echo "$FILE_JSON" | jq -r '.filename')
  ADDITIONS=$(echo "$FILE_JSON" | jq -r '.additions')

  if [ "$ADDITIONS" -eq 0 ] 2>/dev/null; then
    echo "No additions in $FILENAME, skipping."
    continue
  fi

  RAW_PATCH=$(echo "$FILE_JSON" | jq -r '.patch // ""')
  PATCH=$(echo "$RAW_PATCH" | grep -E '^\+' | grep -v '^\+\+\+' | sed 's/^\+//')

  # Fallback: patch still empty (race unresolved, or omitted for large diffs) —
  # review the full file content at the PR head instead of skipping.
  if [ -z "$PATCH" ]; then
    CONTENTS_URL=$(echo "$FILE_JSON" | jq -r '.contents_url')
    PATCH=$(curl -sf --connect-timeout 10 --max-time 30 \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3.raw" \
      "$CONTENTS_URL" 2>/dev/null || true)
  fi

  if [ -z "$PATCH" ]; then
    echo "No content to review in $FILENAME, skipping."
    continue
  fi

  PATCH=$(truncate_content "$PATCH")

  echo "Reviewing $FILENAME..."

  REVIEW=$(get_review_content "$FILENAME" "$PATCH")

  if [ -n "$TOTAL_REVIEWS" ]; then
    TOTAL_REVIEWS="$TOTAL_REVIEWS

---

"
  fi

  TOTAL_REVIEWS="$TOTAL_REVIEWS## \`$FILENAME\`

$REVIEW"
done

if [ -z "$TOTAL_REVIEWS" ]; then
  echo "No content to review."
  exit 0
fi

COMMENT_BODY="$COMMENT_MARKER
# PullProof Review

$TOTAL_REVIEWS

> Generated by [PullProof](https://github.com/SyedSibtainRazvi/PullProof) | Model: $MODEL"

ESCAPED_BODY=$(echo "$COMMENT_BODY" | jq -Rs .)

EXISTING_COMMENT_ID=$(curl -sf -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments" \
  | jq -r ".[] | select(.body | startswith(\"$COMMENT_MARKER\")) | .id" \
  | head -1)

if [ -n "$EXISTING_COMMENT_ID" ] && [ "$EXISTING_COMMENT_ID" != "null" ]; then
  echo "Updating existing comment $EXISTING_COMMENT_ID..."
  curl -sf -X PATCH \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$REPO/issues/comments/$EXISTING_COMMENT_ID" \
    -d "{\"body\": $ESCAPED_BODY}" > /dev/null
else
  echo "Creating new comment..."
  curl -sf -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$REPO/issues/$PR_NUMBER/comments" \
    -d "{\"body\": $ESCAPED_BODY}" > /dev/null
fi

echo "Review posted on PR #$PR_NUMBER"