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

# The model is unreliable at noticing/counting what a post already contains —
# it suggested adding diagrams and references to posts that had them. Compute
# those facts deterministically and hand them to the prompt instead.
content_facts() {
  local content="$1"

  local image_count
  image_count=$(printf '%s\n' "$content" | grep -cE '!\[[^]]*\]\(|<Image[ />]|<img[ />]') || true

  # frontmatter key with a non-empty value; images: [] / image: '' count as absent
  local cover_line cover_image="absent"
  cover_line=$(printf '%s\n' "$content" | grep -m1 -E '^[[:space:]]*(images?|cover|coverImage|hero)[[:space:]]*:' || true)
  if [ -n "$cover_line" ] && ! printf '%s' "$cover_line" | grep -qE ":[[:space:]]*(\[\]|''|\"\")?[[:space:]]*,?[[:space:]]*$"; then
    cover_image="present"
  fi

  local references="absent"
  printf '%s\n' "$content" | grep -qiE '^#{1,6}[[:space:]]*(references|further reading|resources|useful links|read more)' && references="present"

  local link_count
  link_count=$(printf '%s\n' "$content" | grep -oE '\]\(https?://' | wc -l | tr -d ' ')

  printf 'Verified facts about this post (computed programmatically — trust these over your own impression):\n- Inline images/diagrams: %s\n- Cover/hero image in frontmatter: %s\n- References/Further-reading section: %s\n- External links: %s' \
    "$image_count" "$cover_image" "$references" "$link_count"
}

get_review_content() {
  local filename="$1"
  local content="$2"
  local facts="$3"

  local system_prompt="You are PullProof, an expert technical blog reviewer. Review the following blog post and provide structured feedback.

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

The user message includes VERIFIED FACTS about the post (image count, cover image, references section, link count), computed programmatically. Trust them over your own reading. Never suggest adding something the facts show already exists. If a specific section would still benefit from an additional diagram or citation despite what exists, name that exact section and justify why.

When you flag writing issues or suggest rewrites:
- Preserve the author's voice. Match the post's existing tone and rhythm — do not impose a formal or generic style on a conversational post, or vice versa.
- Quote the original text, then suggest the smallest edit that fixes the actual problem.
- Only propose a rewrite for a genuine problem: a grammar error, an ambiguity, or a structure that confuses the reader. \"I would have phrased it differently\" is not a finding.
- Suggested text must read like a human editor wrote it: natural phrasing, no corporate boilerplate, and no inflated vocabulary (\"leverage\", \"delve\", \"crucial\") unless the post itself uses it.

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

  local escaped_prompt=$(jq -n --arg sys "$system_prompt" --arg file "$filename" --arg content "$content" --arg facts "$facts" \
    '{"role": "system", "content": $sys}, {"role": "user", "content": ("File: " + $file + "\n\n" + $facts + "\n\nContent to review:\n" + $content)}' |
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

FILES_RESPONSE=$(curl -sf --connect-timeout 10 --max-time 30 \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$REPO/pulls/$PR_NUMBER/files?per_page=100") || {
  echo "::error::Failed to fetch PR files"
  exit 1
}

MD_FILES=$(echo "$FILES_RESPONSE" | jq -c '[.[] | select(.filename | test("\\.(md|mdx)$")) | select(.status != "removed")]')
FILE_COUNT=$(echo "$MD_FILES" | jq 'length')

if [ "$FILE_COUNT" -eq 0 ] 2>/dev/null || [ "$MD_FILES" = "[]" ]; then
  echo "No .md/.mdx changes found, skipping."
  exit 0
fi

echo "Found $FILE_COUNT file(s) to review"

TOTAL_REVIEWS=""

for i in $(seq 0 $((FILE_COUNT - 1))); do
  FILE_JSON=$(echo "$MD_FILES" | jq -c ".[$i]")

  FILENAME=$(echo "$FILE_JSON" | jq -r '.filename')

  # Review the full post at the PR head, not just the diff additions — the
  # model needs existing images, references, and surrounding prose so it
  # doesn't suggest things the post already has. contents_url is pinned to
  # the head SHA, which also sidesteps the empty-patch race right after a
  # push (the diff may still be computing while the blob is ready).
  CONTENTS_URL=$(echo "$FILE_JSON" | jq -r '.contents_url')
  CONTENT=$(curl -sf --connect-timeout 10 --max-time 30 \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    "$CONTENTS_URL" 2>/dev/null || true)

  if [ -z "$CONTENT" ]; then
    echo "No content to review in $FILENAME, skipping."
    continue
  fi

  CONTENT=$(truncate_content "$CONTENT")

  FACTS=$(content_facts "$CONTENT")
  echo "Reviewing $FILENAME... ($(printf '%s' "$FACTS" | tail -n +2 | tr '\n' ';' ))"

  REVIEW=$(get_review_content "$FILENAME" "$CONTENT" "$FACTS")

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