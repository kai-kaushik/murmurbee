---
title: Example post (copy this file to start a new one)
description: One or two sentences that show up in Google results and link previews.
date: 2026-10-28
draft: true
---

Write the post in Markdown. The file name becomes the address: `my-first-post.md` is published at
murmurbee.com/blog/my-first-post/.

## A heading

Normal paragraphs, **bold**, *italic*, [links](https://murmurbee.com), lists:

- one
- two

> A quote.

| Model | Mistakes per 100 words |
|---|---|
| General | 17.4 |
| Personal | 9.3 |

Delete `draft: true` when it's ready, then run `uv run --with markdown python site/build_blog.py` and deploy.
