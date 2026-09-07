# UBK - Universal Basis Keeper 1.6.1a

**1.6.1a performance update:** reduces repeated purchase-history and tooltip work that could interrupt play. Close WoW and run the updated installer to update both UBK and its TSM integration.

**Every item has a price. Your inventory has a story.**

UBK connects the cost of what you own with the decisions you make in TradeSkillMaster: what to craft, what to sell, and which holdings deserve a closer look.

**For WoW TBC Anniversary. The TradeSkillMaster addon is required.** The TSM Desktop App is optional and recommended for refreshed market data.

## Download and install

Download **UBK-1.6.1a.zip** from this release and extract it. The folder includes **installer.exe**, **source.zip**, the standalone **Interface/AddOns/UniversalBasisKeeper** addon, and documentation.

Close WoW, run the installer, and select your `_anniversary_` client folder. The same installer handles new installations and updates, preserving supported local settings and history. Open WoW and type `/ubk`.

Manual addon placement is available, but the installer supplies the required TSM integration. If that integration is missing, UBK plays the raid-warning sound and prints the repair instruction after login. Close WoW and run the installer to complete it.

## What changed in 1.6.1a

- Reuses the purchase-history export until TSM transaction data changes, and removes unnecessary display-data joins from that export.
- Avoids repeated tracked-material list work during tooltip and accounting-status refreshes.
- Preserves the existing TSM integration, native sources, crafting, temporary selling groups, and return recovery. TSM's normal mailing behavior remains unchanged.
- Includes the earlier 1.6 prospecting cost-capture and settlement hotfix.

A player who experienced repeated town freezes reported no stutter during ordinary movement after the performance fix. See VERIFICATION.txt for completed checks and STRESS-TESTS.md for the live validation scenarios.

**Existing 1.6 users:** run this installer with WoW closed so both the addon and its TSM integration are updated. Keep your saved data and existing operations.

## Position Intelligence

Review what you hold against your recorded basis and loaded market prices. Each row brings together its assessment, basis, price reference, estimated profit per item, quantity, estimated total profit, and regional sale rate.

- Use **Quick Wins**, **All**, **Sell**, **Add**, **Risk**, and **Cost review** to focus the table. Search names, filter by profession, type, quality, or per-item profit, and sort the columns.
- Hover for the reasoning, cost coverage, invested gold, concentration, liquidity, supporting evidence, and specific buy/sell levels. Qualifying holdings also show the estimated sales needed to recover current basis and the stock that would remain.
- Left-click a holding to open **Market Inspector**; right-click to add it to **Watchlist**.

Quick Wins requires fully covered, trusted costs, at least 15% estimated net return, and liquidity not marked thin. Profit estimates include the 5% AH cut and a reserve for one failed 24-hour deposit when vendor value is available. Incomplete costs remain **COST NEEDED**, with profit withheld. Loaded prices are estimates: check current AH listings before acting.

See the [Khorium Bar examination](https://github.com/Jcplugs/UBK-Universal-Basis-Keeper/blob/main/docs/KHORIUM-WALKTHROUGH.md): 83 bars at 4.50g recorded basis, illustrated from the position assessment through a completed live scan and the TSM listings.

## Also in UBK 1.6

- **Cost Coverage and TSM sources:** inspect missing costs, resolve unknown stock, and connect acquisition basis and recipe costs to your TSM workflow.
- **Market Inspector and Scan Mats:** inspect an item, scan its current AH listings, or compare its recipe materials with shopping and vendor quotes.
- **Sell Above Basis:** select bag items for a temporary TSM selling group, preview your basis percentages, post through TSM, and return items to their original groups.
- **Shredder and prospecting:** compare expected raw-gem returns, learn from your own complete prospects, and settle recorded ore expenses into the session's actual outputs after reload.
- **Watchlist, Chum, and Cross-Pressure:** follow holdings and related material opportunities with saved context and visible market signals.
- **Purchase accounting:** capture acquisition evidence during transactions and reconcile after the transaction windows close, with work split into smaller batches.

The addon installs no player's inventory, purchases, watchlist, or yield observations. Documentation screenshots show an existing player session. UBK is an independent community project.

Read **USER_GUIDE.md** for the workflows and **UBK_RELEASE_NOTES.txt** for the detailed changes. **VERIFICATION.txt** and the accompanying test results document automated checks; **STRESS-TESTS.md** covers live in-game checks. Automated checks do not certify every live WoW interaction.
