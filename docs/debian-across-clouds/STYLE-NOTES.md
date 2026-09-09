# House style, read out of dev.to/xbill (4 articles, 2026-08-16..2026-09-08)

Samples used: 4608249 "The Desktop Looked Right" (closest template),
4566708 "ChromeOS Lookalikes", 4435639 "Three Clouds, One Brief",
4398883 "Installing Rust for vLLM on Graviton".

## Front matter
title: "<Evocative claim>: <specific numbers or the second half of the contrast>"
published: false   (flip only at publish time)
series: <linux | ChromeOS | ...>   optional
description: 1-3 sentences, DENSE with the actual numbers. Not a teaser.
tags: 4 max, lowercase, comma-separated
cover_image: content-addressed raw.githubusercontent URL

## Opening, in order
1. One sentence: "This article walks through..." / "This article covers..."
2. A BOLD thesis sentence that reframes the problem.
   e.g. "**Debian tells you almost everything. It just does not tell you on screen.**"
3. Two or three paragraphs establishing the gap/tension, mechanism-first.
4. A bullet list of the concrete findings, with the numbers in bold.
5. A bare repo URL on its own line.

## Section skeleton
## The Machine                  -- table of the rig(s), "measured on <date>"
## At This Point You Should Have -- preconditions bullets, then whether the
                                   steps mutate anything ("Steps 0-3 are reads.")
## Step N — <Imperative Title>   -- em-dash, not hyphen. Each step opens with
                                   why it exists, often "This step exists because..."
## <Analytical sections>         -- named as claims, not labels:
                                   "Why Nothing Looked Wrong",
                                   "What the Theme Declared, and What GTK Served",
                                   "A completed task does not mean you got the answer"
## Cheat Sheet                   -- one fenced block, numbered `#` comments
                                   above each command, mirroring the steps
## Summary / The short version   -- what the goal was, what the key insight was
**Repo:** link block at the very end.

Heading level: `##` and `###` in the newer articles; `####` in older ones.
Per the global CLAUDE.md, `#`/`##` both render title-size on Medium, so the
Medium variant needs `####`. Keep `##` for dev.to and Builder Center.

## Voice
- Declarative. No hedging, no "it seems", no "arguably".
- Mechanism before conclusion. Explain WHY the machine does the thing.
- Em-dashes, heavily.
- Bold on the load-bearing NUMBER, not on the sentence.
- Reversal/aphorism to close a section:
    "and that's a kernel problem before it's a permissions one"
    "Two ChromeOS lookalikes, and only one of them is actually pretending."
    "That GTK version is the whole article, and nothing on the desktop ever mentions it."
- Contrastive section-title pairs: "Where They're Alike" / "Where They Differ",
  "What They Declare, and What They Serve".
- Second person for procedure, first person for what was measured.
- Tables for anything comparative; the multi-cloud piece ran 62 table rows.
- A step whose whole point is a negative result is worth its own section
  ("the error you must refuse to act on").

## Evidence habits already in the corpus
- "measured on <date>" attached to figures.
- A docs/ file in the repo carrying every finding with its date, and a second
  file listing which claims are measured and which are still open.
- Negative controls called out explicitly.
Do not restate a figure that has no artifact behind it.
