# PullProof - AI-Powered Documentation Reviewer 
<img src="https://github.com/user-attachments/assets/292617b9-db98-41c1-ab00-7dfa6ace27dc" width="200"/>

Proofreads every pull request like an editor. PullProof is a GitHub Action that **automatically reviews documentation changes in pull requests** and provides AI-generated feedback using OpenAI.

## Features

- Detects changes in `.md` and `.mdx` files in a PR
- Sends them to OpenAI for analysis
- Posts an **automated review comment** on the PR

## How to Use

Add this workflow to your `.github/workflows/pullproof.yml` file:

```yaml
name: Documentation Review using pullproof
on: pull_request, syn

jobs:
  review-docs:
    runs-on: ubuntu-latest
    steps:
      - name: Run PullProof
        uses: SyedSibtainRazvi/PullProof@v1.0.0
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
```

