# AGENTS.md

Personal Ruby script that exports Monobank (`api.monobank.ua`) FOP statements to CSV.

## Commands

- Setup: `bundle install`
- Run: `bundle exec ruby mono.rb` (Ruby 3.4.2 via `.ruby-version`)
- No tests, linter, formatter, or CI exist. Do not invent `rake`/`rspec`/`rubocop` tasks. `test_kdl.rb` (if present) is an untracked ad-hoc scratch script, not a test suite.
- Run from the repo root. Outside it, rbenv picks the global Ruby 3.4.7 and `bundle exec` fails on the 3.4.2 lockfile.
- `README.md` is the user-facing doc; keep it in sync when behavior changes.

## Architecture

- `mono.rb` is the only entrypoint and holds the `MonobankExporter` module. It only auto-runs under `if $PROGRAM_NAME == __FILE__`, so `require_relative 'mono'` in a scratch script is safe for testing.
- Flow: read `config.kdl` -> resolve period -> per client build a Faraday connection with that client's `token` -> `GET /personal/client-info` -> select every account with `type == 'fop'` -> `GET /personal/statement/{id}/{from}/{to}` -> write CSV.
- One client failing is logged and skipped; other clients still run. `run` logs and returns `1` when any client failed, when `config.kdl` is missing/unreadable/invalid, or when no valid clients remain; otherwise `0`. `run` rescues `StandardError` at both the per-client and top level, so failures are always logged.

## config.kdl

- `clients` node: one `fop "<name>" token=...` per client; the name becomes the output directory.
- Optional `settings` node sets the period via **child nodes** (not properties): `settings { from "2026-01-01" to "2026-01-03" }`, `YYYY-MM-DD` local time, `to` included through end of day. Missing `settings` (or either date) defaults to the previous day.
- `config.kdl` is gitignored and holds live tokens; `config.kdl.template` is the committed shape. Never commit tokens.
- Tokens come only from `config.kdl`. `dotenv`/`.env` are no longer used (the gem was removed from the `Gemfile`); ignore the leftover `.env*` files.

## Output

- CSV: `export/<client name>/<client name>[_<account tag>]_<YYYY-MM-DD_HH-MM-SS>.csv`. The account tag is appended only when a client has multiple FOP accounts.
- Encoding: UTF-8 **with BOM**, delimiter `;`, so Cyrillic opens correctly in Excel. Amounts are converted from kopiykas to `%.2f`.
- Logs: `logs/export.log` (appended) plus stdout. Log reasons for failures (HTTP status + body) but never tokens.

## Gotchas

- Ruby 3.4 removed `csv` from default gems: keep `gem 'csv'` in the `Gemfile` or `require 'csv'` raises `LoadError` under Bundler.
- KDL values: `KDL::Value#to_s` includes the surrounding quotes; use `#value` to get the plain string. Node arguments are positional (`fop "name"`), `key=value` are properties.
- Monobank limits: `client-info` and `statement` are each max 1 request / 60s, and a statement window is max 31 days + 1h. The script chunks long periods and sleeps 60s between statement calls for the same client (per-token throttle; clients do not block each other).
- `.gitignore` ignores `export/` and `logs/` (financial/PII data), plus `config.kdl`, `.env`, `.solargraph.yml`, `Gemfile.lock`, `.ruby-version` — yet `Gemfile.lock` is tracked; editing `.gitignore` will not untrack it.

## Conventions

- Commit messages are in Russian (see `git log`).
- Source is `frozen_string_literal: true`; Russian strings appear in console output and logs.
