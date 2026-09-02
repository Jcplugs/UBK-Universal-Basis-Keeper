# Universal Basis Keeper + Goblin Intelligence

**Universal Basis Keeper (UBK)** and **Goblin Intelligence (GI)** are companion addons for **World of Warcraft: The Burning Crusade Classic** designed to extend TradeSkillMaster with better cost-basis tracking, market inspection, and gold-making workflow tools.

This project is currently a **Release Candidate (RC)** and should be treated as test software.

---

## What is Universal Basis Keeper?

TSM is excellent at tracking markets, crafting, groups, operations, and accounting.

UBK adds a different concept:

> **What did the inventory I currently own actually cost me?**

UBK maintains a moving weighted-average basis for materials you own and can provide that information back to TSM for use in crafting and pricing decisions.

Rather than treating every material as though it was acquired at today's market price, UBK can build a personal cost basis from your own purchases and inventory.

UBK is designed to work alongside TSM — not replace it.

---

## What is Goblin Intelligence?

Goblin Intelligence is a market-analysis and workflow companion for UBK and TSM.

Current features include:

- Market Inspector
- Goblin Radar market hunting
- Plain-English Radar hunt modes
- TSM-aware item inspection
- Shift-click item capture
- Auctioning workflow buttons
- Craft Next integration
- Realm/faction-specific GI data
- Market opportunity analysis using TSM data

GI is intended to help answer questions like:

- Is this item unusually cheap?
- Is this market deep enough to buy into?
- Does this item move quickly?
- Is this realm unusually cheap compared with the region?
- Is the market thin?
- Is this something worth putting on the shelf for later?

---

# Requirements

This release is intended for:

- **World of Warcraft: The Burning Crusade Classic**
- **TSM v4.14.76**

UBK and GI are built around the TBC Classic version of TSM represented in this release.

Do not assume compatibility with Retail, Classic Era, Wrath, or later TSM versions unless a future release specifically says they are supported.

---

# Two Installation Options

The release contains **two different installers**.

Choose the one that matches your situation.

---

## 1. Existing TSM User — SAFE INSTALL

Use:

`UBK_GI_Universal_TBC_RC1_EXISTING_TSM_SAFE_INSTALL.zip`

Choose this if you **already use TradeSkillMaster**.

This package does **not replace your existing TSM installation or SavedVariables**.

It adds:

- Universal Basis Keeper
- Goblin Intelligence
- MyCost setup support

### What happens to my existing TSM setup?

Your existing TSM profile is preserved.

UBK can create a separate profile based on your current active profile so you can experiment with UBK/MyCost without intentionally destroying your original configuration.

Your existing:

- groups
- operations
- profiles
- accounting history
- inventory information
- material settings
- market data

remain your own.

### Existing-user setup

After installing, log into WoW and follow the UBK setup process.

You can also start it manually with:

`/ubk setup`

UBK can examine your existing TSM information and build a proposed starting cost basis from your own data.

It may use information such as:

- current inventory
- TSM Accounting purchase history
- existing TSM material values
- existing material formulas

UBK will **not blindly overwrite uncertain information**.

If it cannot determine a trustworthy historical basis, the item is sent to human review.

Use:

`/ubk review`

to work through those items.

The goal is:

> **UBK learns from your TSM installation instead of asking you to throw it away.**

---

## 2. New TSM User — FRESH INSTALL

Use:

`UBK_GI_Universal_TBC_RC1_FRESH_TSM_INSTALL.zip`

Choose this if you **do not currently have TSM installed** or deliberately want a clean TSM installation.

This package contains:

- TradeSkillMaster v4.14.76
- TSM AppHelper
- Universal Basis Keeper
- Goblin Intelligence
- MyCost setup support

The included TSM core is an unmodified TSM v4.14.76 installation.

The AppHelper data included with the package has been sanitized so another player's realm or market database is not distributed with it.

---

# No Donor Data

The universal package intentionally contains **no personal item database**.

It does not ship with somebody else's:

- inventory
- purchase history
- accounting history
- material basis
- item prices
- crafting queue
- auction history
- characters
- watchlists
- SavedVariables

UBK and GI create their own data for **the person actually using the addon**.

---

# Realm and Character Support

UBK and GI are designed to determine the logged-in player's:

- realm
- faction
- character context

at runtime.

They are not intended to be tied to one person's characters or one specific TBC realm.

Each user builds their own local UBK/GI state.

---

# MyCost

This package provides a TSM custom price framework centered around:

`mycost`

MyCost is intended to provide a personal material-cost source that can be used by TSM crafting and pricing formulas.

Supporting sources currently include:

- `mycost`
- `fairvalue`
- `matvalue`
- `craftsell`

The setup process also configures the associated crafting/material methods used by this project.

**MyCost is enabled as a TSM tooltip source.**

### Important TSM behavior

TSM v4.14 stores some custom-price and tooltip settings globally rather than per-profile.

For that reason, installing MyCost makes those sources available across TSM profiles.

UBK's setup system attempts to preserve previous values before changing supported settings.

---

# First Run

On first use, UBK should guide you through setup.

You can restart or manually invoke the setup process with:

`/ubk setup`

Existing TSM users will generally want the option that imports information from their current TSM environment.

New users can start empty.

---

# Human Review Is Intentional

Historical inventory accounting is not always perfectly reconstructable.

For example:

- you may own an item purchased before TSM began recording it
- an item may have been traded to you
- inventory may have been crafted, looted, converted, prospected, or otherwise acquired outside a clean AH purchase history
- existing TSM history may simply be incomplete

UBK should not pretend those items cost zero.

Instead, uncertain inventory can be flagged for review.

Use:

`/ubk review`

The user remains the final authority over ambiguous starting values.

---

# UBK Ownership

Importing an item into UBK does not have to mean immediately surrendering its TSM material formula to UBK.

The setup/review system is intended to distinguish between:

1. reading existing TSM information
2. establishing a proposed UBK basis
3. allowing UBK to maintain that material going forward

This is deliberate.

UBK is supposed to be conservative with an established TSM installation.

---

# Goblin Intelligence Market Inspector

GI's Market Inspector can be used while TSM is open.

A typical workflow is:

1. Open GI Market Inspector.
2. Select the GI item field.
3. Shift-click an item from your bags or a supported TSM item display.
4. GI loads the item for inspection.

GI is intended to coexist with TSM rather than force you to close the Auction House interface.

---

# Goblin Radar

Goblin Radar includes several hunt styles.

Current modes include:

- **LOW** — unusually inexpensive opportunities
- **DEEP** — larger pools of discounted inventory
- **FAST** — stronger turnover / faster-moving markets
- **SHELF** — inventory worth buying and holding
- **REGION CHEAP** — realm prices unusually low versus regional values
- **RARE** — scarcity-oriented opportunities
- **THIN** — markets with limited available supply
- **ALL** — broader opportunity view

Hover the buttons in GI for a plain-English explanation of what each hunt is trying to find.

---

# Craft Next

GI includes a **Craft Next** helper for the TSM Auctioning workflow.

When appropriate, it appears near TSM's Post controls.

Craft Next is only intended to appear when the relevant profession/crafting window is open.

If the crafting queue contains nothing to craft, the button should not behave as though work is waiting.

TSM remains responsible for the actual queued recipe and craft quantity.

GI is only providing a convenient workflow control.

---

# Useful Commands

### UBK setup

`/ubk setup`

Starts or returns to first-run/setup behavior.

### Review uncertain basis

`/ubk review`

Walk through materials whose starting cost could not be determined safely.

### UBK help

`/ubk help`

Displays available UBK commands for the installed version.

Additional commands may be added or changed during the RC period.

---

# Back Up Your WTF Folder

This is a **Release Candidate**.

Before testing it with an established TSM installation, make a backup of your WoW:

`WTF`

folder.

That is good practice before testing any addon that interacts with another addon's SavedVariables.

The Existing TSM installer is specifically designed to preserve an existing setup, but backups are still strongly recommended during RC testing.

---

# RC1 Safety / Validation

RC1 was packaged with several deliberate safety goals:

- No personal WTF folder is included.
- No donor SavedVariables are included.
- No donor inventory or accounting database is included.
- No preset UBK item basis is included.
- No preset GI market/watch history is included.
- Realm and faction assumptions were removed from the universal build.
- Existing TSM users have a separate safe-install package.
- The included TSM core in the fresh installer was verified against the source TSM v4.14.76 installation used to create the build.
- Custom Lua files were syntax/compile checked during packaging.
- Packaged ZIP integrity was checked.

---

# Important RC1 Limitation

RC1 has been statically and programmatically validated, but the complete universal release could not be tested against every possible real WoW account, realm, profession combination, TSM history, and addon configuration.

This is why the release is labeled:

**RC1**

rather than Final.

Please report anything unexpected.

Particularly useful reports include:

- Lua errors
- TSM errors
- first-run setup problems
- incorrect basis reconstruction
- unexpected profile changes
- items incorrectly classified as resolved/unresolved
- GI buttons appearing in the wrong place
- Shift-click failures
- Craft Next behavior problems
- realm/faction isolation problems

Screenshots and `/buggrabber` / BugSack errors are extremely helpful.

---

# Updating

Unless release notes explicitly say otherwise:

**Do not delete your UBK or GI SavedVariables when updating.**

Replacing the addon folders normally updates the code while preserving your accumulated data.

Always read the release notes before upgrading between major versions.

---

# What This Project Is Not

UBK/GI does not guarantee profit.

It does not know what the market will do tomorrow.

It does not replace judgment.

Market data can be stale, incomplete, manipulated, or temporarily irrational.

The purpose of the project is to give a TSM user better information and better workflow tools — not to automate economic decisions without human oversight.

---

# Release Files

For RC1 you may see:

### Existing TSM

`UBK_GI_Universal_TBC_RC1_EXISTING_TSM_SAFE_INSTALL.zip`

### Fresh TSM

`UBK_GI_Universal_TBC_RC1_FRESH_TSM_INSTALL.zip`

### Complete handoff

`UBK_GI_Universal_TBC_RC1_HANDOFF.zip`

### Verification

`UBK_GI_Universal_TBC_RC1_SHA256.txt`

The handoff ZIP contains the installation choices and supporting documentation together.

---

# File Verification

SHA-256 hashes are provided with the release.

If you download the addon from somewhere other than this GitHub repository, compare its SHA-256 checksum with the checksum published in the official release.

On Windows PowerShell:

```powershell
Get-FileHash .\UBK_GI_Universal_TBC_RC1_HANDOFF.zip -Algorithm SHA256
