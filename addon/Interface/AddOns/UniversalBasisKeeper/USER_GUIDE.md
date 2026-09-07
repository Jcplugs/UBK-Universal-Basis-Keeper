# Universal Basis Keeper — User Guide

Version 1.6.1a · WoW TBC Anniversary

**Every item has a price. Your inventory has a story.**

## Installation and updates

**TradeSkillMaster is required.** Install the [TSM addon for TBC Anniversary from CurseForge](https://www.curseforge.com/wow/addons/tradeskill-master/files/all?page=1&pageSize=20&gameVersionTypeId=73246&showAlphaFiles=hide) first. UBK currently supports TBC Anniversary realms only.

**The TSM Desktop Application is optional and recommended.** UBK cost tracking works without it; refreshed market data makes the market comparisons more useful. Some prices may be missing or stale without the feed. See [TSM's official Desktop Application setup guide](https://support.tradeskillmaster.com/tsm-desktop-application/how-do-i-set-up-the-tsm-desktop-application?from_search=238849512).

1. Close WoW normally so current data is saved.
2. Run `installer.exe` and select the `_anniversary_` client folder containing `WowClassic.exe` and `Interface`.
3. The installer checks for `Interface/AddOns/TradeSkillMaster`. If missing, install TSM and use **Check again**. This prerequisite check does not identify the installed version or search for the Desktop App.
4. Click **Install**. The installer backs up supported existing code and uses the latest local saved data. Existing UBK settings and history are preserved; older separate interface/scanner settings are migrated where needed, and obsolete addon folders are archived outside AddOns.
5. Successful installation confirms **UBK is installed** and **UBK's TSM Integration is installed**. The **Let's go! Time to solo farm the AH!** button closes the dialog; it does not launch WoW.

The folder must retain its `_anniversary_` name; other Classic/Retail folders and custom-renamed client roots are not supported.

This installer serves new and existing users. It includes no player's operations, prices, inventory, or history. Unknown addon/loader edits stop installation rather than being overwritten. Opening the installer alone changes nothing. Administrator rights are needed only if your selected folder's permissions require them.

Version 1.6.1a is the complete addon, including these changes. Use the EXE to install or update it; copying the addon folder alone does not install its TSM integration. `source.zip` is provided for reading and rebuilding. If you downloaded only source, build an installer using `BUILD.txt`, then run that installer.

**Upgrading from 1.6:** run the new installer even if the addon already loads. The performance update includes the UBK-owned TSM integration as well as the addon. Keep your existing SavedVariables and operations; no reset or new configuration is required. The earlier prospecting hotfix is included.

## First visit

Enable UBK on WoW's AddOns screen, open `/ubk`, and begin with **Cost Coverage**. A new account establishes its own opening evidence from retained TSM records or explicit review. An existing account keeps its records.

Open the profession you intend to use so TSM knows its recipes. Check a familiar recipe and inspect Settings > **TSM Sources & Integration**. Installing UBK does not automatically replace all your Crafting, Auctioning, or custom-source formulas. Apply material pricing and operation changes deliberately.

| Command or control | Destination |
| --- | --- |
| `/ubk` or minimap left-click | Home |
| `/ubk dock` | Compact dock |
| `/ubksell` or minimap right-click | Sell Above Basis |
| `/ubk coverage` / `/ubk review` | Cost Coverage / Cost Review |
| `/ubk position` / `/ubk prospecting` | Positions / Shredder: Ores |
| `/ubk market` / `/ubk watch` | Market Inspector / Watchlist |
| `/ubk chum` / `/ubk cross` | Chum / Cross-Pressure playbook |
| `/ubk settings` | Settings |
| `/ubk help` | Additional accounting and setup commands |

The minimap button is draggable. **Craft Next** appears below the active TSM window while a profession is open and requires a real click and ready queued craft. Click UBK, Sources, or TSM to bring that window forward. Sources stays open when the main UBK window closes.

## Costs, coverage, and purchased items

Cost Coverage separates missing evidence from known material costs. Use its **Name** field to search across all pages, combined with the available category filters. **Resolve Unknown** opens the cost dialog; **Use Basis Pricing** adopts the UBK material source and retains the prior formula for restoration. Formula-protected entries need that explicit action before their formulas change.

An unknown quantity is not treated as free. A market listing is not proof of what you paid. UBK records buyer-mail receipts while you collect, and uses TSM's recorded transactions for AH, vendor, and trade purchases. Automatic basis settlement waits until transaction windows close. Reopening one postpones settlement again. Cost Coverage and tooltips identify pending accounting and continue showing the last settled basis until the batch finishes. Trade or other acquisitions without recorded cost evidence remain unresolved. A tooltip's AH-listings status describes market data, separately from acquisition basis.

The same capture-then-settle behavior applies to loot windows. Large purchase histories are prepared in small steps between frames; repeated bag events share one queued settlement. A normal logout or reload retains receipt evidence and resumes pending accounting after login. A client crash can lose changes WoW has not saved. Prospecting keeps its separate recorded-session settlement after reload.

Version 1.6.1a reuses unchanged purchase history and avoids rebuilding the tracked-material list during tooltip/status reads. Changes recorded by TSM refresh that history for the next accounting pass. The settled values and evidence requirements remain the same. This public release retains TSM's existing mail collection behavior.

Optional local preference: `/ubk mail tooltips off` hides common item tooltip windows while the mailbox is open and skips UBK's tooltip additions there. `/ubk mail tooltips on` restores normal behavior. This preference is not enabled for other users by the installer and does not change item costs.

Existing mail and older stock may lack enough evidence for automatic resolution, especially on a new installation. Check the recorded purchase and item quantities before supplying a cost yourself. UBK will not reconstruct a transaction that was never recorded.

Poor-quality grey items stay out of acquisition-cost reviews and UBK's extra basis tooltip. Their **World Drop / Farmed** action uses vendor sell value, including a known zero; a missing quote stays missing. Other loot can carry a labeled working valuation rather than a purchase price. Item links use WoW's quality colors once item information is available.

## Put the TSM sources to work

Open Settings > **TSM Sources & Integration**. An available source is registered with TSM, but can still lack a value for a particular item.

| Source | Meaning | Use |
| --- | --- | --- |
| `ubkbasis` | Trusted known-cost pool value / known quantity; a trusted last basis can remain at zero stock | Acquisition basis |
| `ubkmatcost` | UBK basis, then recorded TSM average purchases, then vendor buy cost | Material planning and selected material overrides |
| `ubkcrafting` | Fully costed reagent total / output count; lowest fully costed known recipe when alternatives exist | Cost of making one item |
| `ubksellbasis` | Confirmed basis for the active temporary selling session | Sell Above Basis operation only |

These are native sources. The guide displays them and existing custom aliases; it does not silently create Custom Sources entries. You may create an unused alias such as `craftbasis` with expression `ubkcrafting` if desired. Check existing names first.

**Use Basis Pricing** assigns `ubkmatcost` when the native bridge is available. A fallback writer can maintain supported material costs without the native source, although the initial TSM material display may need `/reload`. This is planning integration, not a zero-cost resolution of unknown stock.

For your own permanent crafted-gem Auctioning operation, `110% ubkcrafting`, `175% ubkcrafting`, and `500% ubkcrafting` are example minimum, normal, and maximum prices. Configure below-minimum behavior deliberately. Four known cuts each consuming one 5g gem then share 5g50s / 8g75s / 25g prices. UBK does not apply this example to existing groups automatically.

Keep your expected crafted selling value, including any `craftsell`, separate from cost. Averaging cost into a low sale estimate can hide a loss. A TSM Crafting minimum-profit gate needs realistic sale inputs as well as accurate cost. It cannot prevent a deliberate manual craft.

`auctioningopmin`, `auctioningopnormal`, and `auctioningopmax` are TSM's own price sources from the item's **first assigned Auctioning operation**. For example, `check(auctioningopmin,max(45s,95%auctioningopmin-craftbasis))` requires a valid positive Auctioning minimum, then sets the Crafting profit threshold to the larger of 45s and minimum proceeds after a 5% fee minus recipe cost. At 5g cost and a 7g Auctioning minimum, that threshold is 1g65s. It is not a prediction of a sale.

## Market Inspector and Scan Mats

Select an item and press **Inspect**. The actions use that inspected item, even if you subsequently type different text without inspecting it.

| Button | Action |
| --- | --- |
| **Scan Now** | Search the open AH for the inspected item and refresh UBK's live quote. |
| **TSM Browse** | Search that item through TSM Browse. Open the AH and select its Browse page first. |
| **Scan Mats** | Read its learned recipe and quote the materials while keeping the finished item selected. |
| **Resolve Unknown** | Open the cost dialog over Inspector without losing the inspected item. |
| **Prospecting rates** | For supported ores, show the yields and sample counts used by Shredder. |

Finish an active AH scan before starting another. Live quotes show observed quantities, time, and complete/partial status. These actions do not buy or post auctions.

For **Scan Mats**, open the relevant profession if the recipe is missing. A recipe selector handles alternatives; the initial choice is the lowest fully costed known recipe per output. The table shows required quantities, **UBK cost / 1**, **Quote / 1**, and totals per craft/output.

UBK cost is the material planning cost. Quote is the current scan's lowest observed AH unit buyout or a vendor **buy** quote. Vendor sell is what the merchant pays you, so it is not the purchase cost of a vial. Known reagent vials stay off AH searches even when their vendor quote is missing. Other supplies with known vendor buy prices are excluded too.

Missing prices leave an incomplete total. Partial results and limited cheapest-price stock are labeled. Whole-stack purchases, merchant availability, and discounts can change your actual bill. Scanning never overwrites paid basis.

## Sell Above Basis

1. Open the panel and choose eligible bag items. Use name, profession, item type, quality, and optional **Min basis (g)** / **Max basis (g)** filters. Basis boundaries are per item; blank means no boundary.
2. Tick individual rows, use **Select Matching** for all eligible filtered matches across pages, or **Select All** for every eligible bag item type, including hidden rows. **Clear Selection** removes the checklist.
3. Set **Min %**, **Normal %**, **Max %**, and **Singles / type**; click **Preview settings**. Percentages must be positive and ordered. Stack size is always one.
4. Confirm the move. UBK rechecks items and records original groups before using its temporary **zz - sell above basis** group and Auctioning operation. If the name exists, it chooses a suffix.
5. In TSM Auctioning, select that group and run a Post Scan. Make the normal Post/Skip decisions yourself.
6. When the scan and queued decisions finish, accept the return prompt or keep the session. **Return Items** remains available manually and covers the full session regardless of current filters.

Defaults are 110% / 175% / 500% with up to 10 singles per item type, 24-hour duration, and a 1-copper undercut. Below minimum: do not post. Above maximum: post at maximum. At 5g basis, the default prices are 5g50s / 8g75s / 25g. A minimum-price sale leaves 22s50c above basis after a 5% fee, before lost deposits. Custom percentages are gross prices: account for fees when choosing them. TSM checks and existing auctions can reduce the displayed posting cap.

`ubksellbasis` captures trusted acquisition basis at confirmation; a fully costed recipe may supply material basis if acquisition basis is unavailable. Missing-cost, locked, and grey items cannot be selected; soulbound items are omitted. A pending prospecting output blocks its entire item type, including existing known-cost copies, until settlement.

The temporary group has its own Auctioning operation and empty overrides for other operation types. Original group operations remain intact. Returning restores the prior group/inheritance; originally ungrouped items return to Base Group.

Original paths are journaled before moving items. Partial moves reverse; pending returns retry at logout and next login/reload, including another character or profile. The TSM-side recovery loader can return items even when UBK's interface addon is disabled on that character. If an original group was deleted or an item was independently moved elsewhere, UBK retains the conflict for review instead of overwriting it. Correct the group situation in TSM and retry.

Return pending sessions before removing or rolling back the integration. A TSM update may remove its loader; new swaps then become unavailable until compatible integration is restored. The installer blocks older-bridge restoration while a return journal is pending.

## Prospecting: from ore to settled cost

Open **Positions > Shredder: Ores > Load & Rank Ores**. UBK compares Copper, Tin, Iron, Mithril, Thorium, Fel Iron, and Adamantite by expected raw-gem profit **per five ores**. It keeps owned/planning cost, current ore buyout, recent value, and break-even buying price distinct.

Raw-gem income uses loaded gem minimum buyouts less a 5% AH fee. Dust, powder, cut gems, and failed deposits are excluded from this estimate. Missing costs, required gem prices, or usable yields withhold the applicable profit estimate. Expected gems per five ores are quantities, not percentage drop chances.

### Learning yields

Learning is automatic for every supported ore, including Thorium. A sample needs a successful Prospecting cast, complete loot evidence, and exactly five of one ore type disappearing from bags. Ambiguous or incomplete observations are excluded from the learning dataset. Every cast and loot action remains yours.

A valid imported local baseline receives the weight of 20 prospects; complete personal observations gradually contribute more. Without a valid baseline, at least 20 complete personal prospects are required before a sample-based profit estimate is shown. This is a minimum sample rule, not a confidence guarantee. Rare results may be absent from small samples. **Load & Rank Ores** refreshes the comparison; Inspector shows the same yields and sample counts.

The installer reads and validates a baseline from the user's separately installed TSM data. It does not execute the imported source or distribute its coefficients in the public package. If no usable baseline is available, personal learning can still build an estimate. Do not redistribute the generated `UBK_ProspectingData.lua` from your game installation as the public source file.

### Check ore cost and Destroying ignores

**Open TSM Destroying** is available when bags contain more than five of one supported ore across its stacks. Bank stock does not count toward this shortcut. The button runs `/tsm destroy`; TSM still checks your profession and you perform the prospects.

UBK first checks ore cost evidence. If missing, its ore Inspector/Resolve dialog asks you to **tell UBK the ore's basis**. Review the proposed quantities and enter the per-ore cost. Confirmation distinguishes unknown ore still held from unknown ore consumed by recorded prospects; known costs remain intact. Changed inventory or a stale preview requires another review.

**Ignored ores: N — Review** lists supported ores in TSM's saved Destroying ignore list, including those outside your bags. **Remove listed ores from ignore** changes that list only after your acceptance; **Keep ignored** leaves it alone. Other ignored items are preserved. A session-only skip may require reload to clear. Manual prospecting can still be learned while an ore is ignored in TSM.

### Settle a session before selling its outputs

1. Establish ore cost from your records or the explicit resolution above.
2. Prospect normally. UBK records actual inputs and delivered outputs for the login session.
3. Keep those outputs in your inventory until settlement. Reload after finishing the session.
4. UBK pools complete records by session and ore type, then allocates the actual ore expense into the resulting items. Check pending status before beginning a new sale scan.

Relative-value allocation uses output reference quotes captured during the session. If a reference is missing, the entire pool uses a labeled quantity fallback. Every copper of input expense is retained; an unlucky session's loss is not erased. Accounting includes actual recorded outputs, while the prospective ranking described above considers raw gems only.

Existing gem pools keep their prior cost, then receive the settled quantities and allocated expense once. Repeated reloads do not apply the same settlement twice. Resolving a current session's ore cost does not settle its outputs until reload.

Pending output types are withheld from Sell Above Basis, including bulk selection and stale confirmation. A session that becomes pending after its TSM queue was priced is also blocked at final processing. Return Items remains available. Start a fresh selling scan after settlement. This does not undo already-posted auctions or block every other manual crafting/selling route.

Incomplete cast/loot evidence, uncertain delivery, or outputs leaving before settlement remain pending for review. Reload cannot repair missing evidence. Version 1.6.1a does not include a general historical reconstruction tool; preserve the recorded data and report the issue with the version and full message.

## Position Intelligence

Open `/ubk position` and select Position Intelligence. Use it to review the stock you hold against its trusted acquisition basis and the currently loaded TSM price reference.

| Show filter | What it includes |
| --- | --- |
| **Quick Wins** | Fully costed holdings with at least 15% estimated net return and liquidity not marked THIN. This is the default. |
| **All** | All positions returned by the position engine, including holdings needing cost review. |
| **Sell** | SELL HARD, SELL LIGHTLY, and HOLD / SELL SLOW assessments. |
| **Add** | BUY ALL OF THEM and BUY SOME assessments, with their buy ceilings and supporting context. |
| **Risk** | NO ADD, WATCH / THIN, and NO RECENT DATA assessments. |
| **Cost review** | COST NEEDED: holdings without fully covered, trusted acquisition cost. |

1. Choose **All** for a broad review or **Quick Wins** for the qualifying sale shortlist. Use **Refresh positions** after costs or loaded prices change; it refreshes the comparison without starting a live AH scan.
2. Search a name or narrow by profession, item type, quality, and per-item profit. The search covers every page. Click headers to change sorting; use the horizontal scrollbar for more columns.
3. Read **Basis**, **Price ref.**, and **Profit / unit** together. **Qty** and **Total profit** show the size of the holding separately. The default order ranks profit per item, so a large quantity alone does not send an item to the top.
4. Hover the row for its assessment and reason, matching evidence updates, known and unresolved quantities, trusted invested gold, share of fully costed positions, net ROI, liquidity, and regional sale rate.
5. Inspect the price levels in that tooltip. Buy levels are 10% and 15% below basis; sell levels target 5%, 15%, and 25% net return after the AH cut and deposit reserve. Supporting signals and concentration affect the assessment. These levels do not place orders or change your TSM operations.
6. Left-click to inspect that item in **Market Inspector**, where **Scan Now** checks the open AH. Right-click to add it to **Watchlist** for follow-up.

Estimated profit subtracts the 5% AH fee and, when vendor sell value is available, reserves one failed 24-hour deposit per item. Total profit assumes the fully costed holding sells at the loaded reference; it is not earned gold. Regional sale rate is market context, not your personal sell-through rate. Repeated supporting updates describe the evidence behind an assessment; they are not a guarantee of a future price.

For qualifying profitable holdings, the tooltip can show how many units would recover the position's current basis and how many would remain as a **paid runner**. That calculation assumes the displayed net proceeds and becomes real only when those sales occur.

**COST NEEDED** rows withhold profit and basis-backed action guidance. Resolve costs in Cost Coverage before relying on the assessment. A holding can also be absent when the engine has neither a usable basis nor its market fallback; use Cost Coverage for the full cost-review workflow.

## Watchlist and other windows

The **Name** search in Position Intelligence, Cost Coverage, and Sell Above Basis matches any part of the item name, ignores case, and covers all pages. It combines with available filters; **Clear** removes the search. Click column headers to reverse sorting. Wide tables scroll horizontally.

Watchlist keeps the date watching began, recorded acquisition dates where available, starting values, latest loaded minimum buyouts, and sale-rate context. Missing historic values stay missing. Chum investigates price signals; Cross-Pressure keeps related material opportunities and their progression together.

Settings fields provide hover explanations and examples. The Disenchanting Character field is location guidance for owned shredding stock, not an automatic mail instruction.

With Auctionator's supported Shopping results, **Shift-left-click** inserts the item into an open chat draft or opens a draft. **Ctrl+Shift-click** retains the original search-fill action. Other clicks pass through. UBK does not send the message or modify Auctionator's files. Open chat drafts take priority over Inspector link capture.

## Data, integration, and restoration

WoW stores basis history, UI settings, minimap position, and personal yield observations in account-level `SavedVariables/UniversalBasisKeeper.lua`. The temporary group-return journal is saved in the same `TradeSkillMaster.lua` as TSM group assignments. These use WoW's standard save mechanism; gameplay data is not written into the AddOns code folder.

The installer adds the UBK-owned `TradeSkillMaster/UBK_GroupBridge.lua`, its TOC load entry, and journal declaration after checking the supported loader. The bridge calls TSM's internal group/operation and live-ledger paths. The installer backs up the original bytes and does not rewrite your TSM operation/custom-source SavedVariables. The native integration is developed against TSM v4.14.76; unsupported loader changes need a compatible UBK update.

Installer backups live under the selected client's `UBK-Companion-Backups`. **Restore a backup** reverses supported code changes while keeping later basis history and carrying current interface settings back when older separate code needs them. Pending group returns must be resolved first. Unrecognized later edits stop restoration rather than being overwritten.

Keep current SavedVariables when restoring code. Replacing them with an older data checkpoint also discards transactions and settings recorded since that checkpoint.

See `VERIFICATION.txt` for completed checks and `STRESS-TESTS.md` for in-game validation. A useful first check is a familiar purchased item, one known recipe, and a small temporary selling selection followed by Return Items. Neither a passing source test nor a positive displayed margin guarantees an auction sale.

### Thorium Powder credit

New Thorium sessions record powder separately from gems. Its recorded quantity times the vendor sell price is credited against the actual ore expense before allocating the remainder among gems. This is a vendor-value credit, not proof of a vendor sale. Missing vendor data pauses settlement; a known zero price is valid. Gem cost cannot go negative; excess vendor credit is recorded separately. Powder can be sold before gem settlement. Already-settled sessions are not repriced.


Manual addon placement and the integration check

The download includes Interface/AddOns/UniversalBasisKeeper for manual placement.
TSM is required, and the supported client is TBC Anniversary only. Copying UBK
does not install its TSM integration. If the bridge is missing or cannot initialize,
UBK plays the raid-warning sound and prints the repair instruction once after
login. Close WoW and run installer.exe to complete the integration. Working
installations remain quiet. If TSM itself is absent, WoW marks UBK's required
dependency as missing in the AddOns list.
