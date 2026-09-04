# UBK / Goblin Intelligence 1.2.5

## The market has a price. Your inventory has a story.

**Universal Basis Keeper + Goblin Intelligence is an acquisition-accounting and market-intelligence suite for World of Warcraft: The Burning Crusade Anniversary / Classic.**

It gives you two things ordinary price data cannot:

- a defensible answer to **“What did the units I own actually cost me?”**
- a practical answer to **“What deserves my attention before I spend real gold?”**

UBK preserves the economic history of your inventory. Goblin Intelligence turns that history—and the market context already supplied by TradeSkillMaster and AppHelper—into readable workrooms for inspection, comparison, practice, and human decision-making.

**[Download UBK / Goblin Intelligence 1.2.5](https://github.com/Jcplugs/UBK-Goblin/releases/tag/UBK%2FGI-1.2.5)** · **[Learn the two starred rooms](STARRED-ROOMS-GUIDE.md)**

> **Two flagship intelligence rooms. One risk-free practice economy. No automatic trading.**

Target client: **TBC Anniversary / TBC Classic — Interface 20506**

Required data providers: **TradeSkillMaster + TradeSkillMaster_AppHelper**

---

## Built for the moment before you act

TradeSkillMaster can tell you what the market currently thinks an item is worth. UBK/GI answers the questions that appear one step later:

| The question | What UBK/GI brings to the screen |
|---|---|
| What did this inventory really cost? | Persistent acquisition basis, quantity coverage, provenance, and unresolved-cost warnings |
| Am I looking at profit or merely a rising market? | Your committed gold beside current market context and conservative fee-aware references |
| Is this opportunity supported by evidence? | Distinct market observations, visible confidence states, and contradiction handling |
| Is too much of my gold sitting in one place? | Position size, concentration, liquidity context, and basis-improvement references |
| Can I learn the machinery without risking anything? | A sealed Test Arena with fake gold, synthetic inventory, and a fixed market sequence |
| Will the addon act behind my back? | No—every trade, mail, craft, disenchant, post, cancel, bid, and purchase remains yours |

The result is not an auto-trader. It is a workshop that shows its work.

---

## The two starred workrooms

The stars mark the suite’s **flagship rooms**. They are not locks, tiers, or payment markers. Every user can operate both machines.

### ★ Position Intelligence

**See the real shape of what you own.**

Position Intelligence builds a working view of owned inventory with UBK as the authority for genuine acquisition basis. Instead of reducing an item to one market number, it can bring together:

- owned quantity
- UBK acquisition basis
- total gold committed
- known-cost and unresolved units
- current TSM/AppHelper market context
- liquidity context
- portfolio concentration
- basis-improvement references
- conservative, fee-aware exit references

That makes it easier to distinguish a healthy position from an expensive one, a liquid market from a theoretical valuation, and supported cost data from an assumption that still needs review.

Filters and page controls reuse the completed position cache. **Refresh Positions** deliberately rebuilds it when you want a new working view.

### ★ Cross-Pressure

**Study the markets beside the market everyone is watching.**

Cross-Pressure follows linked materials that share a craft. When one driver material becomes cheaper, the economics of the shared craft can improve; that may later support demand for a co-reagent that has not moved in the same way.

The machine does not treat repeated clicks or reloads as fresh evidence. It watches distinct TSM/AppHelper datasets and develops each relationship independently through:

1. **Forming** — the first supported relationship appears.
2. **Strengthening** — a later, distinct dataset supports the same conclusion.
3. **Highly Actionable** — the pattern survives enough independent observations to deserve close human attention.
4. **Contradicted** — new evidence breaks the thesis and weakens or resets it.

Cross-Pressure is designed to make the reasoning visible. A label is an invitation to inspect—not permission to buy blindly.

---

## Practice with house money

Both starred rooms include **Show Test Arena**, which opens the same sealed Golden Geese practice economy. Use **Leave Practice** to return to live work.

Every reset gives you:

- **500g of fake gold**
- **80 fake Felweed** with a **1g 20s basis**
- fake Terocone
- fake Imbued Vials
- a simulated Flask of the Golden Geese craft
- five fixed market updates that teach a conclusion from formation through contradiction
- controls to buy, craft, sell, advance the market, and reset the exercise

The arena lets you feel how position accounting and linked-market evidence behave before any real decision is involved.

### The practice boundary is absolute

Practice activity does **not** alter:

- real character gold
- real bags, bank, or mail
- UBK basis, provenance, ledgers, or coverage
- live Position Intelligence or Cross-Pressure conclusions
- TSM data, profiles, sources, groups, or operations
- Watchlist entries or search state
- crafting queues
- Auction House actions

It is a confidence-building model, not a disguised live mode.

---

## One suite, three focused addons

### UniversalBasisKeeper

The accounting foundation.

UBK tracks acquisition basis for inventory you actually own and keeps that basis separate from changing market opinions. It is built to survive the awkward parts of real inventory life:

- purchases made in multiple batches
- partial sales
- items mailed between your own characters
- buyer mail and inventory movement
- looted or farmed stock
- trades and transformation events
- stock temporarily falling to zero
- mixed quantities where only part of the cost is known

Purchased resale stock, reputation items, investment inventory, keys, gear, and other owned items can carry basis without being pretended into crafting materials.

When the evidence is incomplete, UBK keeps known-cost and unresolved units separate. Missing evidence is not silently converted into free inventory.

### GoblinIntelligence

The visual decision workshop.

`/gi` or `/goblin` opens Home, where health checks, imports, and the major workrooms are one click away:

- **Home** — status, shortcuts, refresh actions, and a guided start
- **Radar** — user-triggered opportunity investigation
- **Market Inspector** — basis, ownership, market, liquidity, and Shredder context in one view
- **Watchlist** — markets worth revisiting across distinct AppHelper observations
- **Shredder** — disenchant-oriented candidates, expected output context, and owned-item workflow
- **Cost Review** — explicit human decisions for inventory whose cost cannot be defended automatically
- **Cost Coverage** — READY, PARTIAL / SAFE, UNKNOWN COST, REVIEW, FORMULA-PROTECTED, and ZERO-STOCK views
- **Settings** — thresholds, scaling, workflow preferences, and supporting controls
- **★ Position Intelligence** — the shape and exposure of owned positions
- **★ Cross-Pressure** — evidence developing across linked markets

Important item surfaces behave like WoW items: hover for the normal tooltip and Shift-click to place the item link in chat.

### TSMMyCostBootstrap

The safe integration layer.

The bootstrap installs the package’s TSM custom-source chain and can clone the active TSM profile into a separate **UBK + MyCost** profile. It preserves the original profile and does not import another player’s groups, operations, accounting history, inventory, or crafting queue.

When the canonical source names are available, the chain is:

```text
fairvalue = avg(dbhistorical,dbhistorical,dbregionsaleavg,dbregionsaleavg,dbrecent)
matvalue  = max(fairvalue,dbrecent)
craftsell = 95%min(dbminbuyout,dbrecent,110%fairvalue)
mycost    = matprice
```

If those names already belong to your own sources, the bootstrap preserves them and installs UBK-prefixed fallbacks instead of overwriting your work.

---

## Features that earn their place

### Acquisition basis that follows the inventory

Mailing an item to another character should not erase what it cost. Buying another batch should not flatten earlier evidence. Selling some units should not make the remainder economically anonymous. UBK maintains continuity across those changes so GI can reason from owned stock rather than a fictional average.

### Provenance you can inspect

Purchase history, buyer mail, captured loot, trades, transfers, and transformations are different events. UBK keeps those distinctions meaningful, and uncertain acquisition paths are routed to review instead of being dressed up as certainty.

### Conservative treatment of farmed and looted stock

Established tracked items can retain a working basis under configured loot rules. First-seen loot without a defensible starting point goes to human review rather than being assigned a convenient zero.

### Transformation accounting

When a supported source item is transformed—most notably through Shredder’s disenchant workflow—UBK can carry its acquisition cost into the real materials produced. If the source cost was unresolved, the uncertainty survives the transformation too.

### Radar that investigates instead of transacting

Radar searches the loaded market context for candidates worth a human look. Hunts are organized as **High-End Materials**, **Common Market Flips**, **Uncommon & Rare**, and **Full Market Sweep**. Confirmed candidates can move into Market Inspector or Watchlist, but GI never purchases them.

### A Market Inspector with the layers together

Open one item and compare UBK basis, provenance, ownership, TSM/AppHelper market context, Shredder information, and refreshed Auction House stock when available. It is the suite’s natural “tell me more” screen.

### A Watchlist that respects real updates

GI compares the newest distinct TSM/AppHelper observation with the previously retained observation. A reload is not automatically treated as a new market event. **Refresh Loaded Data** is available when you know newer AppHelper information is ready.

### A practical disenchant pipeline

Shredder can retain candidates, show expected disenchant context, and open an explicit **Search TSM** path for live confirmation. Owned items move through readable states such as READY, NEEDS MAIL, IN TRANSIT, STORED, and LISTED. It does not auto-buy, auto-mail, or auto-disenchant.

### Honest partial-cost handling

Cost Coverage separates supported units from unresolved units. **Resolve Unknown** shows quantities, the existing basis, and the projected blended basis before commitment, then rechecks the underlying state so a stale dialog cannot overwrite newer information. Already-known units are not casually rebased.

### A complete interface that scales as one workshop

GI uses a fixed **1120 × 700 logical canvas** and scales the complete interface together—fonts, controls, rows, spacing, and page geometry—from **75% to 130%**. It avoids the clipped controls and collapsed layouts produced by shrinking only the outer frame.

Escape navigation is contextual: close a dialog, return from detail to its originating section, return Home, then close GI.

---

## A clear everyday workflow

1. Keep the TSM Desktop App and AppHelper data current.
2. Open `/gi` and choose **Import Newest TSM Data**.
3. Review unresolved acquisition costs when UBK asks for a real decision.
4. Explore Radar, Watchlist, Shredder, or the two starred workrooms.
5. Open Market Inspector before acting on an item.
6. Confirm the live Auction House yourself and make the final decision.

If AppHelper updated after you entered the game, use `/reload` before importing so WoW can load the new SavedVariables.

---

## Install 1.2.5

### Existing TSM user

1. Exit World of Warcraft completely.
2. Make sure TradeSkillMaster and TradeSkillMaster_AppHelper are current.
3. Download and extract the release.
4. Copy these three folders into the TBC Classic / Anniversary `Interface/AddOns` directory:
   - `TSMMyCostBootstrap`
   - `UniversalBasisKeeper`
   - `GoblinIntelligence`
5. Keep your existing TSM and TSM_AppHelper folders.
6. Do **not** delete SavedVariables when upgrading an existing installation.
7. Log in, open `/gi`, and complete any first-run review appropriate to your account.

### Fresh user

Install and initialize TradeSkillMaster and TradeSkillMaster_AppHelper first. AppHelper must populate market data for **your** faction-realm and region; this package does not ship another player’s AuctionDB.

Then install the three folders above and open `/gi`.

---

## Useful commands

| Command | Destination or action |
|---|---|
| `/gi` or `/goblin` | Home |
| `/gi position` | ★ Position Intelligence |
| `/gi cross` or `/gi pressure` | ★ Cross-Pressure |
| `/gi radar` | Radar |
| `/gi market` | Market Inspector |
| `/gi watch` | Watchlist |
| `/gi shredder` or `/gi shred` | Shredder |
| `/gi review` | Cost Review |
| `/gi coverage` | Cost Coverage |
| `/gi settings` | Settings |
| `/gi refresh` | Refresh the newest loaded AppHelper/Watchlist observation |
| `/gi scale` | Show the current scale |
| `/gi scale 75-130` | Set the interface scale |
| `/gi scale reset` | Restore the default scale |
| `/tsmycost status` | Inspect bootstrap source/profile state |

---

## Clean package, clean boundaries

The release contains **no** WTF folder, SavedVariables, player inventory snapshot, purchase archive, character list, preset Watchlist, personal item bases, developer market snapshot, TSM groups, TSM operations, or preselected disenchanter.

A fresh installation learns from the recipient’s own TSM/AppHelper data, inventory, mail, loot, transformations, and explicit review decisions.

The operating rules stay simple:

1. **UBK owns acquisition accounting.** Market opinions cannot rewrite it.
2. **Unknown stays unknown until supported.** Missing evidence is not free inventory.
3. **Movement is not automatically a sale.** Transfers preserve economic identity.
4. **Transformations preserve uncertainty.** Questionable inputs do not become trustworthy outputs.
5. **GI is advisory.** It does not automate transactions or character actions.
6. **Live confirmation belongs to the player.** Cached intelligence is a reason to look, not a reason to act blindly.

---

## What is inside the download

```text
GoblinIntelligence/
UniversalBasisKeeper/
TSMMyCostBootstrap/
RELEASE-NOTES-v1.2.5.txt
STARRED-ROOMS-GUIDE.md
```

The guide provides a plain-English first walkthrough of both flagship rooms and the Golden Geese Test Arena. The release notes provide the concise install-facing summary; this page is the full product tour.

---

## Built to show its work

UBK/GI is for players who want to understand the number underneath the recommendation, the evidence underneath the label, and the uncertainty underneath the inventory.

**Keep the accounting defensible. Keep the intelligence inspectable. Keep the player in control.**
