# UBK / Goblin Intelligence v1.1.0

**v1.1.0 is a major step forward from the original public release.**

The original UBK idea was straightforward: maintain a trustworthy personal cost basis for the crafting materials you actually own, then let Goblin Intelligence combine that with TSM's market context to help you make better decisions.

That foundation is still here. The big difference is that UBK can now follow much more of the actual economic life of your inventory — and Goblin Intelligence is much easier to reach and work from.

## A new, easier Goblin Intelligence interface

![Goblin Intelligence v1.1.0 UI preview](UBK-Goblin-Intelligence-v1.1.0-GI-Preview.png)

One of the most visible changes in v1.1.0 is the redesigned GI experience.

You no longer need to remember a slash command, open the Auction House, or go looking for a launcher inside another TSM/profession window. **UBK and GI now have standalone minimap launchers**, and either mouse button simply opens the same **UBK / GI Home** page.

Home gives you a quick health summary and direct access to:

- Cost Coverage
- Cost Review
- Market Inspector
- Refresh UBK Accounting
- Radar
- Shredder
- Watchlist
- Settings

The window now behaves more like a normal WoW interface: **Escape closes it**, **Shift + drag resizes it**, smaller sizes adjust their visible rows, and item-driven pages use **real TBC item icons with normal hover tooltips**.

The presentation has also moved toward a more WoW-native Goblin Workshop look, with clearer navigation, goblin/brass styling, and the fortune charm along the bottom — without replacing real TBC data with decorative or retail-era content.

> **You will be unusually successful in business.**

## UBK is no longer limited to TSM crafting materials

UBK can now maintain acquisition basis for **purchased items outside TSM's normal crafting-material list**.

That means resale inventory, reputation items, investment stock, keys, gear, and other purchased items can participate in UBK accounting without being turned into fake crafting materials.

UBK also keeps known-cost and unresolved units separate. If part of your current inventory cannot be supported by purchase evidence, those units remain visibly unresolved rather than being treated as free.

## Introducing Shredder

Goblin Intelligence now includes a dedicated **Shredder** workspace for disenchant-based gold making.

Shredder can surface cached disenchant opportunities, show useful value and liquidity context, and provide an obvious **Search TSM** action so you can confirm the actual live auction before doing anything.

It also understands the disenchantable gear you already own through the **Owned Pipeline**, including whether an item is ready on your disenchanter, needs to be mailed, is in transit, is stored, or is currently represented as auction inventory.

Your designated Shredder character is configurable.

## Cost can follow an actual disenchant

When UBK knows the supported acquisition cost of a piece of gear and that item is actually disenchanted, UBK can follow that cost into the **real enchanting materials that were produced**.

Shred History records what was destroyed and what came out. If UBK did not know the source cost, it does not invent one merely because the item was transformed.

## Loot and farmed inventory are handled deliberately

UBK now watches real loot-window activity and keeps looted/farmed inventory distinct from purchases.

If an item already has a trusted basis, UBK can handle new looted units without suddenly pretending they were free purchases. If an item is first encountered through loot and there is no defensible starting basis, it goes to review instead of silently becoming zero-cost inventory.

## Cost Coverage is now something you can work from

The Cost Coverage headings are now clickable filters, so you can immediately focus on READY, PARTIAL / SAFE, UNKNOWN COST, REVIEW, FORMULA-PROTECTED, or ZERO-STOCK inventory.

PARTIAL / SAFE rows also have a **Resolve Unknown** button. The new guided workflow shows the item, the number of unresolved units, and explains exactly what is about to happen.

After entering a per-unit acquisition cost, GI does **not** immediately commit it. You first get a confirmation showing the current basis and the projected new blended basis. Only **Confirm Resolve** changes the accounting, and UBK rechecks the projection immediately before commit so stale numbers cannot be approved accidentally.

## Still built around player control

The larger feature set has not changed the core philosophy:

- **Your TSM setup remains yours.**
- **Unknown cost remains unknown until there is evidence or you review it.**
- **No player-specific inventory/history/SavedVariables are shipped.**
- **No automatic market transactions are performed.**
- Existing TSM users can install UBK/GI without replacing their TSM/AppHelper installation.
- A separate fresh-install path is available for players who do not already use TSM.

## Release versioning standardized

Beginning with **v1.1.0**, UBK / Goblin Intelligence uses a simplified sequential release version and filename format. Future releases will advance from this public version line without feature names or development-history labels in package filenames.

## In one sentence

**The original release taught UBK what your crafting materials cost; v1.1.0 extends that into a broader inventory-accounting and player-driven gold-making workflow that can follow purchased, looted, mailed, and disenchanted inventory while making Goblin Intelligence much easier to use.**

---

### UI preview

A sanitized UI preview image is included with the release as `UBK-Goblin-Intelligence-v1.1.0-GI-Preview.png`. It is intended to show the Goblin Intelligence visual direction and navigation without publishing player inventory, chat, character, realm, or account data.
