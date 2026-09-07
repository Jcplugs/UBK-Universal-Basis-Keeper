# From a holding to the AH: examining Khorium Bars

An actual Khorium Bar examination in UBK 1.6, illustrated with captures taken on the morning of 7 September 2026. Follow the workflow from Position Intelligence through recorded cost, loaded market context, a live AH scan, and TSM listings. The images focus on the relevant windows and controls. Prices vary slightly between captures; these are observations from that morning, not current price advice or sample data installed with UBK.

## 1. Find the holding

With **Show: Quick Wins**, Position Intelligence ranks the holdings by **Profit / unit**. The Khorium Bar row shows **83 owned**, **4.50g basis**, an **8.48g price reference**, about **3.18g estimated profit per bar**, and **264g estimated total profit**. Its assessment is **SELL HARD**.

Quantity and total profit stay beside the per-item ranking, so the player can see both the opportunity per bar and the size of the holding. The price reference comes from loaded market data; Market Inspector displays the live AH quote separately.

![Position Intelligence showing Khorium Bars among the player's holdings](screenshots/ubk-position-overview.png)

## 2. Read the assessment

Hovering Khorium Bar opens the reasoning and price levels. The tooltip identifies the basis as **MANUAL ACQUISITION COST**, with **83 known and zero unresolved**. It shows the estimated return after the AH cut and a reserve for one failed 24-hour deposit, along with liquidity and the evidence state: **Forming, one matching update**.

The same tooltip shows **49 units** as the estimated sales needed to cover this position's current basis, leaving **34 units**. That assumes sales at the displayed loaded reference and costs; it is not a record of completed sales.

![Complete Khorium Bar assessment tooltip, from the SELL HARD reasoning through the price ladder and mouse actions](screenshots/ubk-khorium-assessment.png)

## 3. Examine the recorded cost and market context

Clicking the row opens **Market Inspector** for Khorium Bar. In this pre-scan capture, the **4.50g basis** and full cost coverage remain visible alongside distinct market references: **8.47g AuctionDB minimum buyout**, **8.49g recent realm reference**, and **5.68g regional reference**. The live-quote status explicitly says **not scanned yet**.

This is where the player checks what the first assessment was built from. The loaded data's age is shown as unknown in this session; it is not presented as a freshly observed listing.

![Market Inspector separating recorded Khorium cost from loaded AuctionDB and realm references](screenshots/ubk-khorium-recorded.png)

## 4. Check the live AH

At the Auction House, **Scan Now** searches for the inspected item. This completed scan shows a live quote rounded to **8.44g**, **919 units observed**, and the timestamp **11:55:58**. The quote and quantity describe that completed scan. They are separate from the **83 bars owned** and the **4.50g recorded basis**.

Scanning updates the live quote without replacing acquisition cost. This close-up keeps the scan result, recorded basis, cost coverage, and loaded references together.

![Market Inspector detail showing a completed 8.44g live scan with 919 units alongside the unchanged 4.50g acquisition basis](screenshots/ubk-khorium-live-scan.png)

## 5. Open the listings in TSM

**TSM Browse** opens the exact-item search. This later capture shows **Scan Complete**, sellers, stack sizes, and unit buyouts, with the lowest visible listing at **8g44s04c**. The full TSM results window is visible, including the controls below the list.

The sequence stops at examination. It shows how a player checks an opportunity before deciding what to do; it does not show a completed sale or realized profit.

![TSM's completed exact Khorium Bar search with visible listings and auction controls](screenshots/ubk-khorium-tsm-listings.png)

[Return to the overview](../README.md) · [Position Intelligence instructions](../USER_GUIDE.md#position-intelligence)
