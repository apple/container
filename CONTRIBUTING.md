# 🌈 📦️ Welcome to the Container community! 📦️ 🌈

Contributions to Container are welcomed and encouraged.

## How you can help

We would love your contributions in the form of:

🐛 Bug fixes\
⚡️ Performance improvements\
✨ API additions or enhancements\
📝 Documentation\
🧑‍💻 Project advocacy: blogs, conference talks, and more

Anything else that could enhance the project!

## Submitting Issues

To file a bug or feature request, use [GitHub issues](https://github.com/apple/container/issues/new).

🚧 For unexpected behavior or usability limitations, detailed instructions on how to reproduce the issue are appreciated. This will greatly help the priority setting and speed at which maintainers can get to your issue.

## How do I pick something to work on?

In case you don't have anything specific to work on, you could
start off by picking a [good first issue](https://github.com/apple/container/contribute). Before you start
working on an issue:
* Check the comments, assignees, and any references to pull requests — make sure
  nobody else is actively working on it, or awaiting help or review.

* If someone is assigned to the issue or volunteered to work on it, and there
  are no signs of progress or activity over at least the past month, don't
  hesitate to check in with them — it might be that the person moved on.

* Leave a comment that you have started working on it.

> [!IMPORTANT]
> If you plan to make substantial changes or add new features, we encourage you to first discuss them with the wider container developer community.
> You can do this by filing a [GitHub issue](https://github.com/apple/container/issues/new).
> This will save time and increases the chance of your pull request being accepted.

### Getting Help

Once you start working on the issue, you will inevitably end up having a lot of questions. Don't be afraid to ask for help! The codebase is large and wrapping your head around it will take time. When asking for help, prefer giving as much information as possible, while highlighting the parts that you think are important. Refer to the [section](#-Maintainers-to-ping-for-help) below for the appropriate maintainers to ping.

### Maintainers to ping for help

// TODO

### I didn't get a response from someone. What should I do?

It's possible that you ask someone a question in a issue/pull request and
you don't get a response as quickly as you'd like. If you don't get a response
within a week, it's okay to politely ping them using an `@` mention with a
reminder. If you don't get a response for 2-3 weeks in a row, please ping
someone else.

### I can't finish the contribution I started. :frowning_face:

Sometimes an issue ends up bigger, harder, or more time-consuming than expected — **and that’s completely fine.**
Be sure to comment on the issue saying you’re stepping away, so that someone else is able to pick it up.

## Pull Requests

We require all commits be signed with any of GitHub's supported methods, such as GPG or SSH. Information on how to set this up can be found on [GitHub's docs](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification#about-commit-signature-verification).

To make a pull request, use [GitHub](https://github.com/apple/container/compare). Please give the team a few days to review but it's ok to check in on occasion. Refer again to this [section](#-Maintainers-to-ping-for-help) for the appropriate maintainers to ping. We appreciate your contribution!

We use a "squash and merge" strategy to keep our `main` branch history clean and easy to follow. When your pull request
is merged, all of your commits will be combined into a single commit.

With the "squash and merge" strategy, the *title* and *body* of your pull request is extremely important. It will become the commit message
for the squashed commit. Think of it as the single, definitive description of your contribution.

Before merging, we'll review the pull request title and body to ensure it:

* Clearly and concisely describes the changes.
* Uses the imperative mood (for example, "Add feature," "Fix bug").
* Provides enough context for future developers to understand the purpose of the change.

The pull request description should be concise and accurately describe the *what* and *why* of your changes.

#### .gitignore contributions

We do not currently accept contributions to add editor specific additions to the root .gitignore. We urge contributors to make a global .gitignore file with their rulesets they may want to add instead. A global .gitignore file can be set like so:

```bash
git config --global core.excludesfile ~/.gitignore
```

#### Formatting Contributions

Make sure your contributions are consistent with the rest of the project's formatting. You can do this using our Makefile:

```bash
make fmt
```

#### Applying License Header to New Files

If you submit a contribution that adds a new file, please add the license header. You can do this using our Makefile:

```bash
make update-licenses
```

### AI Contribution Guidelines

We welcome thoughtful use of AI tools in your contributions to this repository. We ask that you adhere to these rules in order to preserve the project's integrity, clarity, and quality, and to respect maintainer bandwidth:

* You should be able to explain and justify every line of code or documentation that was generated or assisted by AI. Your submission should reflect your own understanding and intent.
* Use AI to augment, not totally replace, your reasoning or familiarity, especially for non-trivial parts of the system. 
* Avoid dumping AI-generated walls of text that you cannot explain. Low-effort, unexplained submissions will be deprioritized to protect maintainer bandwidth.

AI tools should be used to **enhance, not replace** the human elements that make OSS special: learning, collaboration, and community growth.

## Code of Conduct

To clarify of what is expected of our contributors and community members, the Container team has adopted the code of conduct defined by the Contributor Covenant. This document is used across many open source communities and articulates our values well. For more detail, please read the [Code of Conduct](https://github.com/apple/.github/blob/main/CODE_OF_CONDUCT.md "Code of Conduct").
