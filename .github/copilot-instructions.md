# Copilot Instructions

These rules help Copilot understand how to behave in this project. Follow them consistently to maintain quality and team conventions.

---

## Rule: @translation - Chinese Prompt Translation Workflow

**When to Apply**:
When the user prompt is written in Chinese.

**What to Do**:
1. Translate the prompt from Chinese to English before using it.
2. Generate a response based on the English version.
3. Translate the final result back into Simplified Chinese before presenting it.

**What NOT to Do**:
- ❌ Do not translate or modify code blocks.
- ❌ Do not change technical terms like function names, class names, or libraries.
- ❌ Do not translate log/output/print messages inside code—they must stay in English.

**Constraints**:
- ✅ Use clear, concise Simplified Chinese.
- ✅ Preserve formatting and indentation.
- ✅ If the prompt is already in English, skip translation entirely.

---

## Rule: @auto_review_ui - UI Development Guidelines

**When to Apply**:  
When working in the `auto_review_ui` project directory.  

---

**What to Do**:
1. ✅ Use `yarn add <pkg>` for dependencies and `yarn add -D <pkg>` for devDependencies.
2. ✅ Use `npx shadcn@latest add <component>` when installing ShadCN UI components.
3. ✅ **Determine the dev server port dynamically**:
   - Check ports `3000`, `3001`, `3002` to find an existing service:
     ```bash
     PORT=$(for p in 3000 3001 3002; do
       ss -ltn '( sport = :'$p' )' | grep -q LISTEN && { echo $p; break; }
     done)
     ```
   - If none of the ports are in use, start the server on port `3000` in the background:
     ```bash
     if [ -z "$PORT" ]; then
       nohup yarn dev --port 3000 >/dev/null 2>&1 &
       PORT=3000
     fi
     ```
   - Verify the server is responding:
     ```bash
     curl -I http://localhost:$PORT
     ```
   - **For front-end page data/state validation**, use a headless browser to open the page and check UI state (e.g., with Puppeteer or Playwright).

---

**What NOT to Do**:
- ❌ Do not use `npm install`—always use `yarn`.
- ❌ Do not use `npx shadcn-ui@latest` (deprecated path).
- ❌ Do not start the server manually without checking ports first.
- ❌ Do not start the server manually in the foreground—**the dev server must always run in the background**.
- ❌ Do not use `lsof` to check port usage (it does not reliably support IPv6). Use `ss -ntpl | grep :<port>` instead.

---

**Constraints**:
- ✅ Maintain consistency in package management (yarn only).
- ✅ Add components using the official scoped CLI.
- ✅ Always check ports dynamically and use an existing service port for testing.
- ✅ If no port is in use, automatically start the dev server in the background.
- ✅ Use a simulated browser when validating front-end page data or state.
- ✅ Dev server **must never run in the foreground** under any circumstances.
