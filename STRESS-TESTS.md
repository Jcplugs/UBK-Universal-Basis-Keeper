# UBK 1.6 — focused live tests

Start with **START-HERE.txt** and run the installer while WoW is closed.
The installer updates UBK and its TSM integration and preserves a backup. These
are live checks for behavior already implemented; source tests have passed.

| Priority | Action | Expected result |
|---|---|---|
| 1 — purchases | Record Dawnstone / Nightseye's known quantity and basis. Collect a few bought gems individually, then a batch. Keep a tooltip open during collection. | While mail is open, accounting stays pending. Close the mailbox: each newly accounted purchase contributes its actual price and quantity in the batch. Existing stock blends with purchases. Same-price purchases may increase quantity without visibly changing the average. The settled tooltip updates without duplicate lines. |
| 1 — capture windows | Buy at the AH, collect mail, purchase vendor supplies, and complete a recorded paid trade. Close each transaction window, including walking away from the mailbox and using the TSM close button. Try reopening during settlement. | No automatic basis changes while any transaction window is open. Closing the last window queues settlement; reopening postpones it without losing receipt evidence. Missing paid-trade evidence stays unresolved. |
| 1 — responsiveness | Collect a full bought-mail batch with long TSM history, then run a normal TSM AH browse/post scan. Optionally enable `/ubk mail tooltips off`. | No UBK per-invoice history scan while collecting; no automatic UBK reconciliation while the AH is open. Tooltip preference applies only at the mailbox. Record any remaining hitch or Lua timeout with its stack. |
| 1 — replay | Record known quantity and basis, then reload twice without buying, selling or crafting. | No repeated purchase, extra quantity or second charge. If TSM already accounted for a purchase before a tooltip opened, receipt must not add it again. |
| 1 — prospect block | With a known-cost ore, prospect several batches. Include a raw gem you already own with a valid basis. Open Sell Above Basis. Try its checkbox, Select All, Select Matching, and a selection made before prospecting. | Pending item types are unchecked and disabled; bulk selection excludes them. Confirmation refuses stale selections. Existing resolved copies of the SAME gem type are also blocked while that type has pending outputs. |
| 1 — prepared queue | Select a gem in Sell Above Basis and let TSM prepare a post queue. Prospect more of that gem before clicking Post. | Final posting is blocked while the selling session contains pending gems. Return Items or reload/settle and start a fresh scan. A price calculated before the prospect must not bypass the block. |
| 1 — settlement | Record ore quantity and its basis before prospecting. Finish the session, then reload. | Actual consumed ore costs are pooled by ore type and login session, distributed by frozen relative output values, and blended into existing gem pools. Pending quantities settle once when inventory evidence is ready. Reload again: unchanged. |
| 2 — unknown ore | Use ore with unknown cost. Click Open TSM Destroying or Resolve Ore Costs. Also try manually prospecting the final five unknown ore. | UBK checks acquisition evidence and asks for the ORE's per-unit cost in its Inspector/Resolve dialog. Review shows remaining unknown ore separately from already-consumed unknown ore. No invented replacement ore appears in inventory. |
| 2 — mixed ores | Prospect two different ore types before reloading. | Their cost pools stay separate, even when both produce the same gem. |
| 2 — interrupted loot | Interrupt a cast; on a separate completed cast, leave some loot uncollected or test a full bag. | Failed casts do not mint gem basis. Incomplete loot evidence stays pending and blocked. Preserve the session for inspection rather than manually assigning gem prices. |
| 2 — learning | Prospect supported ores including Thorium; inspect their yield counts. | Complete five-ore results increment once; duplicate loot notifications do not increment twice. Learning is automatic without a Thorium toggle. |
| 3 — materials | Inspect a known craft such as Flask of Blinding Light with profession and AH open. Click Scan Mats, then use the separate current-item TSM Browse button. | Actual recipe quantities load; vials/vendor supplies are excluded from AH searches. The product remains selected. Current-item Browse searches the product, not its materials. |
| 3 — ignore list | Put one supported ore on TSM's Destroying ignore list. Open the UBK offer, decline, then reopen and accept. | Declining changes nothing. Acceptance removes only the listed ores. Other ignored items remain; a temporary session skip may require reload. |
| 3 — Auctionator links | Shift-left-click a Shopping search result with chat open, then closed. Try Ctrl+Shift-click and ordinary clicks. | The item link enters an existing chat draft or opens a draft. Nothing is sent. Ctrl+Shift keeps search-fill; normal buy/history clicks keep their behavior. |
| 3 — tables and layout | Search an item in Coverage, Positions and Sell Above Basis; use combined ranges and reverse sorting. Check Settings at 106% scale. | Search covers all pages; sale ranges are inclusive; singles stay stack size one; Disenchanting Character does not overlap the explanation. |

A losing prospecting session remains a loss: allocation cannot make the market
pay more. If any output lacks a usable quote, the entire pool uses the explicitly
labeled quantity fallback, which is less useful for distinguishing cheap and
expensive gems. Normal allocation uses the recorded relative values. Quotes do
not become ore acquisition costs.

Incomplete or moved-output evidence remains blocked for review; it is not
silently released. Avoid selling, crafting, mailing or deleting provisional
outputs before settling. This draft does not reconstruct prospecting done before
its capture code was loaded or unsaved observations lost in a client crash.

If something fails, send the exact error and a screenshot showing known,
unresolved and pending quantities, plus the item, price/quantity paid and action
that caused it. After closing WoW normally, the current UBK and TSM SavedVariables
contain the useful session and purchase evidence. Do not reset those files.
