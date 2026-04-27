# Auto Review System

> An end-to-end automated code review platform powered by LLMs, designed for enterprise R&D teams.  
> Performs static analysis and security auditing on C/C++ commits, covering diff extraction, AI report generation, result persistence, and web visualization.

---

## Repository Structure

This is a **Git Submodule monorepo**. Clone with:

```bash
git clone --recurse-submodules git@github.com:xdlhzdh/auto_review_ws.git
```

| Submodule | Description |
|-----------|-------------|
| [`auto_review`](https://github.com/xdlhzdh/auto_review) | LLM review engine (Puppeteer + TypeScript) |
| [`auto_review_ui`](https://github.com/xdlhzdh/auto_review_ui) | Web dashboard (Next.js 15 + PostgreSQL) |
| [`code_diff`](https://github.com/xdlhzdh/code_diff) | C/C++ diff extractor (Python, function-level granularity) |
| [`CppCodeAuditor`](https://github.com/xdlhzdh/CppCodeAuditor) | LLM audit prompt library for C/C++ |

Root-level scripts orchestrate the full pipeline across all submodules:

| Script | Purpose |
|--------|---------|
| `run_review_and_update_db.sh` | Main pipeline: clone repos → diff → LLM review → persist to DB |
| `run_review.sh` | Single-shot review runner |
| `run_review_service.sh` | Long-running service mode (used with systemd) |
| `parse_review.py` | Parse HTML review reports → JSON → Gerrit comment push |
| `update_last_commit.sh` | Update the last-processed commit record per repo |
| `db_backup_service.sh` | Periodic PostgreSQL backup |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Pipeline Layer                      │
│   Shell scripts  ·  Python  ·  TypeScript (cron)    │
└───────────────────────┬─────────────────────────────┘
                        │
         ┌──────────────┼──────────────┐
         ▼              ▼              ▼
  ┌─────────────┐ ┌──────────┐ ┌────────────────┐
  │  code_diff  │ │auto_review│ │  auto_review_ui│
  │  (Python)   │ │  (TS/Node)│ │  (Next.js 15)  │
  └─────────────┘ └──────────┘ └───────┬────────┘
                        │              │
                        ▼              ▼
                 ┌─────────────┐  ┌──────────────┐
                 │  LLM Backend│  │  PostgreSQL   │
                 │ CompanyGPT /│  │  (Prisma 6)   │
                 │ GH Copilot  │  └──────────────┘
                 └─────────────┘
```

### Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | Next.js 15 (App Router), React 19, TypeScript, Tailwind CSS, Radix UI, Chart.js, diff2html |
| Backend API | Next.js Route Handlers (BFF), SSE real-time push |
| Database | PostgreSQL 16, Prisma 6 ORM |
| AI Invocation | Puppeteer browser automation, dual LLM backend (internal GPT / GitHub Copilot) |
| LLM Proxy | Go microservice — OpenAI-compatible REST, OAuth Device Flow, auto token refresh |
| Python Toolchain | GitPython + unidiff (diff parsing), BeautifulSoup (report parsing), atlassian-python-api (Confluence) |
| Auth | Azure MSAL (OAuth 2.0 + PKCE, cookie persistence + auto-renewal) |
| Infrastructure | Docker Compose (3 services: UI, PostgreSQL, LLM proxy), Node Alpine + Chromium + Python venv |

---

## Core Features

### 1. Function-Level Diff Extraction (`code_diff`)
- Extracts parent–child diffs per commit, focusing on C/C++ source files (`.c`, `.cpp`, `.h`, etc.)
- Splits change blocks at **function granularity**, producing structured JSON for LLM consumption
- Filters out test directories and third-party dependencies

### 2. LLM Review Engine (`auto_review`)
- Builds prompts from audit rules (e.g. multi-threading safety, C++ best practices) combined with repo-level tags
- Drives the LLM via Puppeteer; supports both internal GPT and GitHub Copilot
- Produces structured HTML reports; `parse_review.py` converts them to JSON and persists to DB; optionally posts comments back to Gerrit

### 3. Scheduling & Batch Processing
- **Scheduled batch mode**: Shell scripts iterate over cloned Git repos, with file-lock + `LastCommit` for idempotent incremental execution, driven by cron
- **Manual trigger mode**: Submit a Gerrit Change ID → validate status (Open, mergeable) → enqueue (max concurrency 25) → async worker execution with 20-minute timeout
- **Real-time progress**: SSE broadcasts queue progress and task completion events

### 4. Web Dashboard (`auto_review_ui`)
- Statistics view: review status distribution (`Passed` / `Risky` / `Skipped`), confirmation status, pie charts, paginated list — filterable by project, author, and time range
- Review detail page: side-by-side commit diff and AI report; engineers can mark each comment as valid/invalid
- Feedback loop: per-file/function engineer feedback recorded in DB; optionally archived to Confluence

### 5. GitHub Copilot Proxy (Go microservice)
- OAuth Device Flow + token lifecycle management
- Exposes OpenAI-compatible endpoints (`/v1/chat/completions`, `/v1/models`)
- Health check and pprof endpoints; independently deployable via Docker

---

## Database Schema (key tables)

| Table | Description |
|-------|-------------|
| `Review` | Core review record; unique key `(repoName, commitId)`; stores `reviewStatus`, AI report JSON, comment counts |
| `ReviewFeedback` | Engineer feedback per file+function; unique key `(repoName, commitId, filePath, functionLocation)` |
| `LastCommit` | Last processed commit per repo — ensures incremental batch execution |
| `User` / `Settings` | Logged-in users and per-user preferences (preferred LLM source, model version) |
| `CopilotUser` | GitHub Copilot OAuth token and expiry |
| `Cache` | Generic key-value cache to reduce redundant API calls |

---

## Quick Start

### Prerequisites
- Docker & Docker Compose
- SSH access to Gerrit (for automated comment push, optional)
- Azure AD app registration (for SSO, optional)

### 1. Configure environment

```bash
cp auto_review_ui/.env.example auto_review_ui/.env
# Edit .env with your DB credentials and service URLs
```

### 2. Start services

```bash
cd auto_review_ui
docker compose up -d
```

### 3. Run a review

```bash
# Batch mode (iterate all repos under ./repos/)
./run_review_and_update_db.sh

# Single repo / single commit
./run_review.sh --repo <repo-path> --commit <commit-sha>
```

---

*Project type: Enterprise internal developer productivity tool | Status: Production*
