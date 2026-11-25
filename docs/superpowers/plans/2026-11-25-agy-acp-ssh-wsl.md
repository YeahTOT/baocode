# Antigravity ACP for SSH and WSL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Run official Antigravity CLI from BaoCode SSH and WSL projects and build the Windows installer.
**Architecture:** Use the existing resilient Bao remote client for a Linux process and host-scoped discovery and storage. Keep the current ACP translation and interactive approvals.
**Tech Stack:** Flutter, Dart, Bao remote, ACP, GitHub Actions, Inno Setup.
**Spec:** docs/superpowers/specs/2026-11-25-agy-acp-ssh-wsl.md

- [ ] Verify the fork is an exact fast-forward of upstream.
- [ ] Exercise SSH and WSL location plumbing and ACP transport against a fixture.
- [ ] Enable model selection, host-scoped sessions and secure MCP forwards, with no local credential fallback.
- [ ] Run relevant tests and compile Windows x64; verify the SHA-256, source commit and artifact.
