# PullProof - AI-Powered Blog & Documentation Reviewer
<img src="https://github.com/user-attachments/assets/292617b9-db98-41c1-ab00-7dfa6ace27dc" width="200"/>

Proofreads every pull request like an editor. PullProof is a GitHub Action that **automatically reviews blog posts and documentation changes** in pull requests and provides AI-generated feedback.

## What It Reviews

| Dimension | What's Checked |
|-----------|---------------|
| **Metadata & SEO** | Title, description, date, author, tags — presence and quality |
| **Technical Accuracy** | Code examples, language tags, correctness of commands |
| **Writing Quality** | Grammar, spelling, clarity, tone consistency |
| **Structure & Flow** | Intro hook, logical progression, conclusion, heading hierarchy |
| **Blog Polish** | Cover image, references, length, visual aids |

## Features

- Detects changes in `.md` and `.mdx` files in a PR
- Only reviews **added lines** (ignores deletions)
- Posts a **structured review comment** with ratings table and actionable feedback
- **Updates the same comment** on subsequent pushes (no comment spam)
- Configurable OpenAI model

## Usage

Add this workflow to `.github/workflows/pullproof.yml`:

```yaml
name: Documentation Review
on:
  pull_request:
    types: [opened, synchronize]
    paths:
      - "**.md"
      - "**.mdx"

jobs:
  review-docs:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - name: Run PullProof
        uses: SyedSibtainRazvi/PullProof@v2.0.0
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          # model: gpt-4o  # optional, defaults to gpt-4o
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `github_token` | Yes | — | GitHub token for PR access and commenting |
| `openai_api_key` | Yes | — | OpenAI API key for AI review |
| `model` | No | `gpt-4o` | OpenAI model to use |
