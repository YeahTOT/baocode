# Antigravity ACP on Linux SSH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the Antigravity kernel for BaoCode Linux SSH projects.
**Architecture:** Route the kernel to a host-scoped runtime; use existing remote process and loopback-forward APIs without a new server protocol. Convert identities only at the ACP boundary.
**Tech Stack:** Flutter/Dart, BaoCode SSH RPC, Google's stdio ACP, GitHub Actions.
**Spec:** docs/superpowers/specs/2026-11-23-agy-linux-ssh.md

## Global Constraints
- Linux SSH first; mixed hosts not passed as ACP workspaces; credentials never read/copied to desktop.
- Work from upstream b9b32dd and use a dedicated fork preview branch. No main/Codex mutation or release publication.

## Review Focus
- Same raw session ID on two hosts never crosses history, settings, or delete.
- Dead worker is not confused with a transient detached SSH channel.
- Non-Linux hosts cannot launch tools; remote MCP retains loopback and token.
- Artifact build is not proof of live Google sign-in or a paired phone session.
- Existing local installation, account and agent flows remain isolated.

## Tasks
- [ ] Red/green host path, session key, capability setup, and per-host model/limit cache tests in test/kernel/antigravity_kernel_test.dart.
- [ ] Red/green remote runtime fixture: real byte framing through process API, auth lifecycle, catalog replay, close, authenticated MCP forwarding.
- [ ] Red/green catalog tests: exact folder, independent host caches, safe scoped deletion.
- [ ] Extend remote/mobile integration tests for start/resume, prompt approvals, cancel, reconnect and image/screenshot payloads; verify the existing safety gates.
- [ ] Run targeted and regression tests, review and push only the preview branch, run Windows workflow and verify the exact artifact bytes and SHA-256.
