# Development notes — Universal Basis Keeper 1.6

This public source tree contains generic addon, integration, installer, documentation, and test code. It contains no player snapshot or seeded purchase history. See `UBK_RELEASE_NOTES.txt` for the user-facing changes since 1.4.

## Cost evidence and live receipts

`UBK_PurchaseLedger.lua` tracks cumulative quantities as live purchase rows grow. The TSM bridge exposes current purchase data to the core; saved CSV and captured buyer invoices remain fallback evidence. Overlap matching avoids replaying the same purchase after refresh or reload. Deferred receipt bookkeeping observes committed transactions while inventory reconciliation waits for usable bag/mail state. `UBK_LiveTooltip.lua` refreshes the displayed basis information.

The purchase tests use synthetic quantities and prices. They are not bundled transaction records or claims about any player's exact purchases. UI status distinguishes live AH availability from acquisition evidence.

## Prospecting observation and accounting

`UBK_ProspectingLearning.lua` validates successful casts, complete loot snapshots, and a five-ore bag change for the yield dataset. All seven supported ores learn automatically. Valid local coefficients receive a 20-prospect prior weight; absent a usable baseline, sample estimates require 20 complete observations. That threshold is not a statistical confidence bound.

`UBK_ProspectingSessions.lua` records actual outputs and their ore-input costs. The core adapter reserves provisional quantities separately from other unresolved stock. Sessions settle after reload, grouped by session and ore type, using captured relative-value weights or a pool-wide quantity fallback. Cost allocations retain the full ore expense. Journal state and cost pools share SavedVariables, and repeated refresh/reload is idempotent.

Input resolution distinguishes unknown consumed ore from remaining unknown stock. Preview tokens and inventory-sync checks reject stale confirmations. Incomplete observations and output outflow retain pending evidence for review; this version does not reconstruct unobserved historical prospects.

Pending item types are excluded from Sell Above Basis selection and confirmation. The session source withholds its value, and the bridge guards final TSM post processing if a selling session becomes pending after its queue was prepared. Return/recovery remains available. Other manual sale/craft routes remain outside this workflow.

## UI and scanner changes

Material scans read TSM's learned recipes, request targeted non-vendor AH quotes, and retain the selected finished item. Vendor buy quotes are distinct from merchant sell prices. Tables label incomplete prices, partial scans, and limited cheapest-price stock.

The TSM Browse action targets the currently inspected item. Ore Inspector rates share the Shredder estimator. The Destroying shortcut checks bagged ore, offers explicit saved-ignore removal through TSM, and requests missing ore cost first.

Name search spans pages on Positions, Coverage, and Sell Above Basis. Bulk selection and basis filters operate on eligible items; the temporary selling group preserves original group paths and fixes stack size at one. Auctionator's supported Shopping rows receive UBK-owned chat-link handling, with original behavior retained for other actions and Ctrl+Shift search-fill.

## Distribution and maintenance

The installer serves fresh and existing users, verifies file compatibility, preserves local saved data, and records backups. Version 1.6 is delivered as a complete installer for new and existing users. Source is supplied for review and rebuilding, not for copying directly into AddOns. The installer applies both UBK and its checked TSM integration.

Build from the generic source tree. Preserve the separation between public source placeholders and data generated from a user's installed TSM. No build action implies permission to publish or install into a live client.

`VERIFICATION.txt` records completed automated/fixture checks. `STRESS-TESTS.md` records the live scenarios still needing observation. Tests for learning and allocation do not establish the accuracy of rare-yield estimates or guarantee a profitable auction outcome.
