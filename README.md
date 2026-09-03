# Universal Basis Keeper + Goblin Intelligence

**Acquisition-basis accounting and player-driven market intelligence for World of Warcraft: The Burning Crusade Anniversary / Classic.**

Universal Basis Keeper (UBK) and Goblin Intelligence (GI) are designed to sit **on top of TradeSkillMaster**, not replace it. TSM already does an enormous amount of work collecting Auction House, accounting, crafting, inventory, regional, and market information. UBK adds a persistent acquisition-cost layer for the items you actually own, while GI turns that cost information and the current TSM/AppHelper market context into practical screens for reviewing opportunities, understanding cost coverage, following disenchant inventory, inspecting markets, and deciding what deserves a human look.

The project is intentionally conservative about automation. It does not buy, bid, post, cancel, mail, disenchant, or craft for you. The goal is to improve the information available **before you make the decision yourself**.

Current public release: **v1.1.7**

Target client: **TBC Anniversary / TBC Classic — Interface 20506**

---

## What the suite contains

The public repository contains three addons:

- **UniversalBasisKeeper** — acquisition-basis, provenance, coverage, purchase-history interpretation, loot handling, mailbox tracking, and transformation accounting.
- **GoblinIntelligence** — the visual intelligence layer: Home, Radar, Market Inspector, Watchlist, Shredder, Cost Review, Cost Coverage, Settings, and the visible ★ Cross-Pressure preview.
- **TSMMyCostBootstrap** — safely installs the package's TSM custom-source chain and profile settings without replacing an existing TSM profile or importing somebody else's groups and operations.

### Required external addons / data

Normal operation requires:

- **TradeSkillMaster**
- **TradeSkillMaster_AppHelper**

AppHelper is not treated as an incidental extra. GI relies heavily on the TSM/AppHelper AuctionDB data currently loaded for the user's faction-realm and region. Watchlist comparisons, Market Inspector context, Radar inputs, Shredder market context, and other GI views become incomplete or stale when AppHelper data is missing or old.

The usual TSM Desktop App workflow should therefore be kept current so the user's own AppHelper data can populate normally.

UBK/GI does **not** replace TSM or ship another player's TSM database.

---

# The idea behind UBK

TSM can tell you what the market thinks an item is worth. That is not the same question as:

> **What did the units I currently own actually cost me?**

UBK is built around that distinction.

A useful cost basis needs to survive more than a single purchase. Inventory gets mailed between characters, partially sold, looted, bought in multiple batches, transformed into other materials, temporarily reduced to zero stock, or mixed with units whose origin is uncertain. Treating every unexplained unit as free makes profit calculations look wonderful while quietly making them wrong.

UBK therefore keeps acquisition accounting separate from GI's market opinions. GI may tell you that something looks attractive or unattractive; it does not get to rewrite the underlying basis merely because the market moved.

### Broader inventory coverage

UBK is not limited to the items TSM currently considers crafting materials. Purchased resale stock, reputation items, investment inventory, keys, gear, and other purchased items can carry acquisition basis without being converted into fake crafting materials.

Where cost evidence is incomplete, UBK separates known-cost and unresolved units rather than silently assuming the unresolved portion cost zero.

### Provenance matters

UBK distinguishes meaningful acquisition paths. Purchase history, buyer mail, captured loot, trades, inventory movement, and transformation events are not all treated as the same economic event.

Cross-character movement is particularly important: mailing your own item to another character should not erase its cost or pretend the receiving character obtained it for free.

### Loot and farmed inventory

Looted/farmed inventory is deliberately distinct from purchased inventory. Established tracked items can retain a conservative working basis under the configured loot rules, while first-seen loot with no defensible starting point is routed to human review instead of being assigned a fictional zero cost.

### Transformation accounting

When UBK can support the acquisition cost of an item that is actually transformed — most notably through Shredder's disenchant workflow — it can follow that cost into the real materials produced.

If the source cost is unresolved, the transformation does not magically clean up the uncertainty. UBK keeps the uncertainty visible.

---

# Goblin Intelligence

GI is the cockpit for the suite. `/gi` or `/goblin` opens the same Home workspace, and the standalone minimap launchers provide another route into the interface.

The UI is designed around **decision support rather than transaction automation**. When GI surfaces an opportunity, the next action is still yours.

## Home

Home is the central landing page. It provides a health summary and shortcuts into the primary workflows so you do not need to remember where a particular feature lives.

From Home you can reach Cost Coverage, Cost Review, Market Inspector, Radar, ★ Cross-Pressure, Shredder, Watchlist, and Settings. Home can also expose useful status and user-triggered refresh actions such as Shredder AH stock updates.

## Radar

Radar is a **user-triggered Auction House investigation** rather than an always-on auto-trader.

It uses the available UBK and TSM context to surface candidates worth inspecting. Confirmed opportunities can be filtered, inspected, or added to the Watchlist. GI never buys anything on your behalf.

The thresholds used for candidate ranking and labels can be adjusted in Settings. Those settings affect GI's interpretation of market opportunities; they do not change UBK acquisition basis or TSM `mycost`.

## Market Inspector

Market Inspector puts the economic layers next to each other:

- UBK acquisition basis and provenance
- current TSM/AppHelper market context
- ownership information
- Shredder context when the item is disenchantable
- currently refreshed AH-stock information when available

Item icons and names behave like WoW items: hover for the normal tooltip and Shift-click to place the item link in chat.

The Inspector can be opened from multiple GI workflows, which makes it the natural "tell me more about this item" screen.

## Watchlist

Watchlist is intended for markets you care enough about to revisit.

GI records the newest distinct TSM/AppHelper data available to the session and compares it with the previously retained observation rather than treating every `/reload` as a brand-new market event. A manual **Refresh Loaded Data** action is available when you know newer AppHelper information has been loaded.

Items can be added from other GI pages, including Radar and Market Inspector.

## Shredder

Shredder is a dedicated disenchant-oriented workspace.

It can build and retain a candidate list, provide expected disenchant context, and offer an explicit **Search TSM** path so the player can confirm the live Auction House before acting.

Its Owned Pipeline follows disenchantable items you already own through practical states such as:

- READY
- NEEDS MAIL
- IN TRANSIT
- STORED
- LISTED

The designated disenchanter is configurable. On a fresh public installation there is no developer character baked into the addon; the current character is used as the initial neutral default.

Live AH-stock checks remain user-triggered and serialized. Shredder never auto-buys or auto-mails inventory.

When a tracked item is actually disenchanted, UBK can carry supported source cost into the real enchanting-material output and record the transformation in Shred History.

## Cost Review

Cost Review is where the addon deliberately asks for a human decision instead of manufacturing certainty.

It is used for inventory whose acquisition cost or provenance cannot be defended automatically. Manual cost is intended to represent a real acquisition-cost decision, not a convenient number chosen to make an item appear profitable.

## Cost Coverage

Cost Coverage shows the state of the owned inventory rather than just a single blended number. Categories include states such as:

- READY
- PARTIAL / SAFE
- UNKNOWN COST
- REVIEW
- FORMULA-PROTECTED
- ZERO-STOCK

The category headings are clickable filters.

For PARTIAL / SAFE inventory, **Resolve Unknown** provides a guided workflow. The addon shows the known quantity, unresolved quantity, existing basis, and projected blended basis before anything is committed. The final confirmation rechecks the underlying state so a stale dialog cannot silently overwrite newer information.

Already-known units are not rebased merely because the unresolved portion is being reviewed.

---

# ★ Cross-Pressure

The public interface includes a visible **★ Cross-Pressure** workspace so users can see the concept and the style of information the feature is designed to present.

In the public repository it is an **invitation-only locked preview**. The demo page uses fictional item names, fictional prices, and non-actionable examples. The public source does not contain the live item relationships, learned evidence, live trigger/entry/scale/exit calculations, or actionable decision engine used by granted-access installations.

Clicking the padlock opens the invitation-key dialog. Invalid attempts are limited per UI session; `/reload` or relog resets the session counter.

Invitation access is **not sold**. There is no paid tier, subscription, donation gate, or real-world purchase path. **No real-world payment is accepted or required.** Access, when granted, is personal and invitation-only. Contact Jc regarding access.

This is intentionally a relatively small part of the public package. The rest of UBK/GI remains fully usable without Cross-Pressure access.

---

# Universal scaling and UI behavior

A recurring problem with addon interfaces is that "resizing" only shrinks the outer frame while the contents continue to assume a fixed pixel layout. That eventually produces clipped rows, overlapping labels, and controls drawn on top of one another.

Beginning with v1.1.6, GI uses a **fixed 1120 × 700 logical canvas** and scales the entire workshop as one unit. Fonts, buttons, rows, spacing, and page geometry stay in proportion instead of being crushed independently.

Supported scale range: **75%–130%**.

You can control it with:

- `/gi scale` — show the current scale
- `/gi scale 90` — set GI to 90%
- `/gi scale reset` — return to the default 95%
- Settings presets — 75%, 90%, 100%, 115%, and 130%
- lower-right corner drag — scale the complete GI window
- Shift-drag — scale the complete workshop
- normal drag — move the window

Page subtitles are kept to a safe single-line display; hovering them shows the complete explanation when needed.

Escape navigation is contextual: close a dialog first, return from detail view to the section that opened it, then Home, then close GI.

---

# TSM MyCost Bootstrap

`TSMMyCostBootstrap` exists so UBK can integrate with TSM without bulldozing an established setup.

On setup it can clone the user's active TSM profile into a separate **UBK + MyCost** profile while preserving the original. Package custom sources are installed globally because that is how the supported TSM version stores those sources.

When canonical names are free, the source chain is:

```text
fairvalue = avg(dbhistorical,dbhistorical,dbregionsaleavg,dbregionsaleavg,dbrecent)
matvalue  = max(fairvalue,dbrecent)
craftsell = 95%min(dbminbuyout,dbrecent,110%fairvalue)
mycost    = matprice
```

If the user already has conflicting custom sources with those names, the bootstrap preserves them and installs UBK-prefixed fallback names instead of overwriting the user's existing formulas.

The bootstrap ships **no groups, operations, Accounting history, inventory, crafting queue, SavedVariables, or per-item material prices**.

Useful command:

- `/tsmycost status` — report installed names, conflicts, and setup state

---

# Installation

## Existing TSM user

1. Exit World of Warcraft completely.
2. Make sure your TSM and TSM AppHelper installation is current.
3. Copy these folders into the TBC Classic / Anniversary `Interface/AddOns` directory:
   - `TSMMyCostBootstrap`
   - `UniversalBasisKeeper`
   - `GoblinIntelligence`
4. Keep your existing TSM and TSM_AppHelper folders.
5. Do **not** delete SavedVariables when upgrading from an earlier UBK/GI release.
6. Log in and open `/gi`.
7. Complete any UBK first-run review/setup prompts appropriate to your account.

## Fresh user

Install and initialize TradeSkillMaster and TradeSkillMaster_AppHelper first. AppHelper needs to populate **your own** realm/region AuctionDB data; UBK/GI does not ship somebody else's market database.

Then install the three UBK/GI folders above and follow the normal first-run setup.

---

# Useful commands

### Goblin Intelligence

- `/gi` or `/goblin` — Home
- `/gi home`
- `/gi radar`
- `/gi cross` or `/gi pressure` — ★ Cross-Pressure page
- `/gi shredder` or `/gi shred`
- `/gi market`
- `/gi watch`
- `/gi review`
- `/gi coverage`
- `/gi settings`
- `/gi refresh` — refresh the newest loaded AppHelper/Watchlist observation
- `/gi scale`
- `/gi scale 75-130`
- `/gi scale reset`

### UBK / MyCost

UBK provides its own setup, status, review, and accounting commands; GI surfaces the primary workflows visually. `TSMMyCostBootstrap` also provides `/tsmycost status` for source/profile inspection.

---

# Privacy and public-distribution rules

This repository is intended to be usable by players on any supported TBC Anniversary faction-realm without inheriting somebody else's account state.

The public package contains **no**:

- WTF folder
- SavedVariables
- player inventory snapshot
- player purchase ledger/archive
- account or character list
- preset watchlist
- developer realm/faction market snapshot
- TSM groups or operations
- personal item bases
- private Cross-Pressure relationship/history seed
- personal real-world artwork or artifacts

A fresh installation learns from the recipient's own TSM, AppHelper, inventory, mail, loot, transformation activity, and explicit review decisions.

The public Shredder also contains no preselected developer character.

---

# Player-control and accounting rules

The project deliberately keeps several boundaries firm:

1. **UBK owns acquisition accounting.** GI can read cost/ownership context but market opinions do not rewrite basis.
2. **Unknown stays unknown until supported.** Missing evidence is not treated as free inventory.
3. **Moving inventory is not automatically a sale.** Cross-character movement should preserve economic identity.
4. **Transformations preserve uncertainty.** A questionable source cost does not become trustworthy just because the item was disenchanted.
5. **GI is advisory.** No auto-buy, auto-bid, auto-post, auto-cancel, auto-mail, auto-disenchant, or auto-craft.
6. **Live AH confirmation remains the player's responsibility.** Cached intelligence is a reason to look, not permission to transact blindly.

---

# What changed after v1.1.0?

A lot.

The v1.1.0 release established the modern public foundation: broader UBK inventory coverage, loot-aware accounting, Shredder, the Owned Pipeline, disenchant transformation accounting, Cost Coverage resolution, Home/minimap access, and a much more complete GI interface.

Since then the project has gained contextual navigation, stronger provenance requirements, better live-AH refresh behavior, safer Cost Coverage resolution, improved item interactions, a mailbox-scanner compatibility fix, the ★ Cross-Pressure invitation workspace, explicit invitation/no-payment policy, and — importantly for everyday use — the universal fixed-canvas scaling system that keeps GI readable across window sizes.

v1.1.7 also performs another public-distribution scrub: account-specific historical material is not shipped, personal defaults are removed, the invitation preview is fictional/non-actionable, and the release is packaged around each user's own TSM/AppHelper data.

For the complete version-by-version history, see **`CHANGELOG.txt`**.

---

# Release philosophy

UBK/GI is built for players who want the addon to show its work.

A market tool is much more useful when you can tell **why** something is being surfaced, what cost assumption is underneath it, whether the inventory is actually supported by evidence, and whether the current data is fresh enough to deserve action.

That is the direction of the project: keep the accounting defensible, keep the market intelligence inspectable, keep the player in control, and keep public releases clean enough that another player can install the addon without inheriting the developer's auction house.
