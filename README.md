# OvernightCoder

You're paying for Claude Code and Codex subscriptions. But when you go to bed, those subscriptions sit idle. OvernightCoder fixes that.

Give it a list of tasks, go to sleep, and wake up to pull requests.

## The Problem

Most developers work on one thing at a time. Your backlog piles up. Meanwhile, you're paying for AI coding tools that do nothing for 8+ hours every night.

OvernightCoder takes your to-do list and works through it while you sleep. For each task, it:

1. Creates a separate branch so nothing conflicts
2. Writes tests first, then writes the code to pass them
3. Gets the code reviewed automatically by Codex
4. Opens a pull request (or merges it for you)
5. Moves on to the next task

In the morning, you get a summary of what got done and links to every PR.

## What You Need

Before using OvernightCoder, make sure you have:

- **A Mac or Linux machine with systemd** (it keeps your computer awake overnight — uses `caffeinate` on macOS or `systemd-inhibit` on Linux)
- **Claude Code** with the [Superpowers](https://superpowers.so) plugin installed
- **Codex CLI** installed from [github.com/openai/codex](https://github.com/openai/codex) (run `codex --version` to check)
- **GitHub CLI** installed from [cli.github.com](https://cli.github.com) and logged in (run `gh auth status` to check)
- **A project on GitHub** with a test suite already set up

## Installation

### Option A: Copy-paste this prompt into Claude Code

Open Claude Code and paste this entire block:

```
Install the overnight-coder skill and its dependency, the codex-review-loop skill. Run these two commands:

git clone https://github.com/eishan05/codex-review-loop ~/.claude/skills/codex-review-loop
git clone https://github.com/eishan05/OvernightCoder /tmp/OvernightCoder && cp -r /tmp/OvernightCoder/skills/overnight-coder ~/.claude/skills/overnight-coder && rm -rf /tmp/OvernightCoder

Then verify both skills are installed by listing the contents of ~/.claude/skills/overnight-coder and ~/.claude/skills/codex-review-loop.
```

### Option B: Install manually

```bash
# 1. Install the codex-review-loop skill (required dependency)
git clone https://github.com/eishan05/codex-review-loop ~/.claude/skills/codex-review-loop

# 2. Install overnight-coder
git clone https://github.com/eishan05/OvernightCoder /tmp/OvernightCoder
cp -r /tmp/OvernightCoder/skills/overnight-coder ~/.claude/skills/overnight-coder
rm -rf /tmp/OvernightCoder
```

## How to Use It

**1. Write a to-do list file in your project.** Any format works. For example, a `TODO.md`:

```markdown
- [ ] Add user login with email and password
- [ ] Fix the bug where the homepage redirects twice
- [ ] Add a Stripe payment page
- [ ] Write an API endpoint for user profiles
```

**2. Open Claude Code in your project folder and type:**

```
Use the overnight-coder skill with TODO.md
```

**3. Answer two quick questions:**
- **Merge preference** - pick `autonomous` if you want PRs merged automatically, or `review` if you'd rather look at them yourself in the morning
- **Sequential or parallel** - sequential is safer (one task at a time), parallel is faster (groups independent tasks together)

**4. Go to sleep.** OvernightCoder keeps your computer awake and works through the list. Keep the lid open or configure your OS to not suspend on lid close.

**5. Check the summary in the morning.** You'll see which tasks succeeded, which failed (and why), and links to every pull request.

## How It Works (Plain English)

For each task on your list, OvernightCoder:

- Makes a clean copy of your code in a separate folder (so tasks don't step on each other)
- Writes tests for what the task should do
- Writes the code to make those tests pass
- Pushes the code and opens a pull request on GitHub
- Asks Codex to review the code (up to 9 review passes)
- Fixes anything Codex flags
- Merges the PR or leaves it for you, depending on what you chose
- Clears its memory and moves on to the next task

If a task fails, it tries once more with a fresh start. If it fails again, it logs why and moves on - one bad task won't block the rest.

## Resuming a Stopped Run

If your run gets interrupted (power outage, accidental close, etc.), just run the same command again:

```
Use the overnight-coder skill with TODO.md
```

It saves progress to a state file, so it'll ask if you want to pick up where you left off.

## Configuration

The default Codex review model is `gpt-5.4` with high reasoning effort. To change this, edit the file at:

```
~/.claude/skills/overnight-coder/implementer-prompt.md
```

Look for the `Model:` and `Reasoning effort:` lines in the Codex Review Loop section.

## License

MIT
