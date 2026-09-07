# Universal Basis Keeper — UBK 1.6

**Every item has a price. Your inventory has a story.**

Universal Basis Keeper is a companion to TradeSkillMaster for **WoW TBC Anniversary realms**. It connects purchase evidence, material costs, and practical review tools so you can see what your stock cost before deciding what to make or sell.

A market quote answers what someone is asking today. Your basis answers what you have invested. UBK keeps both on the desk. TSM handles your crafting queue and auctions; UBK gives those decisions a cost record you can inspect.

## What you need

**The TradeSkillMaster addon is required. UBK does not work without it.** [Get the TBC Anniversary TSM addon from CurseForge](https://www.curseforge.com/wow/addons/tradeskill-master/files/all?page=1&pageSize=20&gameVersionTypeId=73246&showAlphaFiles=hide).

TSM's Desktop Application is **optional and recommended**. UBK can track costs without it, but refreshed market data makes the comparisons more useful. Missing or stale quotes limit what any auctioning tool can tell you. [TSM's official Desktop Application setup guide](https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application?from_search=238849512) explains that connection.

## Install and take a first look

1. Close WoW and run `installer.exe` for a new installation or an update.
2. Choose the `_anniversary_` client folder containing `WowClassic.exe` and `Interface`. The installer checks for TSM, backs up supported old code, and preserves your local history and settings.
3. Open WoW, enable UBK, and type `/ubk` or click its minimap button.
4. Begin with **Cost Coverage**. Check a familiar material, open your profession, and inspect one recipe. Settings > **TSM Sources & Integration** explains the available cost sources.

The EXE installs the complete addon and its TSM integration for new and existing users. You can also copy the supplied `Interface/AddOns/UniversalBasisKeeper` folder into your client. If the required integration is missing, UBK warns after login; close WoW and run `installer.exe` to complete it. The `source.zip` archive contains the complete build source.

Installing UBK does not rewrite all your personal TSM operations. The [User Guide](USER_GUIDE.md) explains how to connect them.

## A cost is different from a sale price

Consider a hypothetical evening: you buy twenty Living Rubies at **55g each**, but your configured TSM material formula still values them at **30g**. A cut consuming one ruby appears to sell for **45g**.

After the 5% faction-AH fee, each sale returns 42g75s. Against the configured cost, it appears to earn 12g75s. Against your purchase, it loses 12g25s. Selling all twenty leaves you **245g down**, before any lost deposits.

With the purchase recorded and UBK material pricing applied, the recipe shows the 55g cost. A realistic sale estimate and positive TSM Crafting minimum-profit rule can then exclude it from restocking. You can inspect another cut, compare selling the ruby raw, or wait. UBK does not prevent deliberate manual crafting or make an unprofitable market profitable.

This example concerns a configured cost input, not an unavoidable flaw in TSM. TSM already supports custom prices. UBK's contribution is maintaining acquisition evidence and making the connection to those prices visible.

## Where to begin

| Area | What you can do |
| --- | --- |
| **Cost Coverage** | Search materials by name, inspect missing costs, resolve unknown stock, and adopt basis pricing while retaining the previous material formula. Grey vendor trash stays out of the review queue. |
| **Market Inspector** | Inspect one item, use **Scan Now** for a live AH quote, open its **TSM Browse** search, or **Scan Mats** to compare recipe costs with current shopping quotes. Vials and known vendor supplies stay off the AH shopping list. |
| **Sell Above Basis** | Select eligible bag items, set basis boundaries and posting percentages, then temporarily give them a dedicated TSM Auctioning group. Return them to their recorded original groups afterward. Stack size stays one. |
| **Shredder: Ores** | Rank expected raw-gem profit per five ore, inspect yield sources, and open TSM Destroying. Complete personal prospects strengthen the local estimates. Recorded ore expenses settle into actual outputs after reload. |
| **Position Intelligence** | Search and sort holdings by profession, item type, quality, and value. Compare per-item opportunities without letting a large quantity dominate the view. |
| **Watchlist** | Keep dates, starting values, latest loaded minimum buyouts, and sale-rate context together in sortable columns. |
| **Chum and Cross-Pressure** | Investigate price signals and keep a playbook of related materials and the opportunities you are following. |
| **Sources & Integration** | See UBK's native TSM sources, existing custom aliases, availability, and worked gold examples. Keep this window open alongside the main interface. |

**Craft Next** remains below the active TSM window while a profession is open. It requires your click. The minimap button opens Home on left-click and Sell Above Basis on right-click.

## A small example to try

Four known cuts that each consume one gem with a 5g material cost all have a 5g recipe basis. Their demand and expected selling prices can differ. UBK's `ubkcrafting` source keeps that recipe-cost anchor consistent; a crafted sale estimate remains a separate input.

Sell Above Basis defaults to **110% / 175% / 500%** of its confirmed session basis, with up to **10 singles per item type**. You can change those percentages and the cap before confirming. At 5g basis, the defaults are 5g50s / 8g75s / 25g. The minimum is a posting rule. Buyers may not pay it; include fees when choosing your percentages.

Pending prospecting outputs stay out of Sell Above Basis until their session costs settle. If a gem type is pending, existing copies of that type are also withheld from that workflow. Read the [prospecting workflow](USER_GUIDE.md#prospecting-from-ore-to-settled-cost) before your first batch.

## Accounting that waits until you finish

While the AH, mailbox, trade, vendor, or loot window is open, UBK retains acquisition evidence and leaves automatic basis updates queued. After transaction windows close, it reconciles the batch. Cost Coverage shows when accounting is pending. This keeps repeated history checks out of collecting mail and browsing auctions; it does not change the game's auction-query limits.

## Your records, on your PC

This package includes no player's account, inventory, purchases, watchlist, or personal yield observations. Each account uses its own evidence. WoW saves UBK history and settings through its normal SavedVariables; TSM saves the temporary-group return journal beside its group data. The addon is an independent community project, not an official TSM product.

Read the [User Guide](USER_GUIDE.md), [inside cover](docs/INSIDE-COVER.md), [basis explanation](docs/UNDER-THE-HOOD-BASIS.md), and [changes since 1.4](UBK_RELEASE_NOTES.txt). The [source build instructions](BUILD.txt) describe `source.zip`. Automated checks and remaining in-game checks are documented in [VERIFICATION.txt](VERIFICATION.txt) and [STRESS-TESTS.md](STRESS-TESTS.md).


Manual addon placement and the integration check

The download includes Interface/AddOns/UniversalBasisKeeper for manual placement.
TSM is required, and the supported client is TBC Anniversary only. Copying UBK
does not install its TSM integration. If the bridge is missing or cannot initialize,
UBK plays the raid-warning sound and prints the repair instruction once after
login. Close WoW and run installer.exe to complete the integration. Working
installations remain quiet. If TSM itself is absent, WoW marks UBK's required
dependency as missing in the AddOns list.
