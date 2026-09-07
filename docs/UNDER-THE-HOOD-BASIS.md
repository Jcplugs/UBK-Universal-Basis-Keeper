# Under the hood: what UBK means by basis

**Every item has a price. Your inventory has a story.**

UBK separates acquisition evidence, crafting estimates, and market values. The distinction matters because they answer different questions.

## The cost pool

For tracked stock with trusted acquisition evidence, unit basis is the known-cost pool's value divided by its known quantity. Ten known gems costing 50g total have a 5g basis. An eleventh gem with no cost evidence stays unresolved; it does not dilute the pool as a free item.

Paid purchases enter through TSM Accounting or captured AH buyer-mail evidence. UBK matches overlapping evidence so the same purchase is not counted twice, including when a live TSM purchase row grows as more units arrive. Open tooltips refresh when the recorded cost or quantity changes.

Version 1.6.1a reuses the bridge's purchase export until TSM transaction data changes. Tooltip and status reads use the current settled database without repeating material setup. These changes reduce repeated work; purchase matching, evidence requirements, and the meaning of basis remain the same.

A retained purchase average is useful history, but it is not automatically proof of the price of every unexplained item. Missing history and ambiguous inventory changes remain review work. Explicit player resolutions record the cost the player confirms.

Farmed or looted values can be working valuations rather than paid prices. UBK labels those origins. Its existing non-grey loot rule can use 95% of pre-loot basis; that is an imputation, not a receipt. Grey vendor trash is excluded from routine coverage review, and its World Drop / Farmed action uses vendor sell value when known.

## Four native TSM sources

| Source | Calculation or role |
| --- | --- |
| `ubkbasis` | Trusted known-cost pool value divided by known quantity; trusted last basis may remain at zero stock. |
| `ubkmatcost` | First usable value from UBK basis, TSM recorded average purchases, then vendor buy price. Market prices are not fallbacks. |
| `ubkcrafting` | Total learned-recipe reagent cost divided by output count. With alternatives, use the lowest fully costed known recipe. |
| `ubksellbasis` | The confirmed basis for an item in its active Sell Above Basis session. Pending prospecting outputs withhold this value. |

The material fallback order supports planning without writing historical averages or vendor quotes into unknown inventory as invented purchases. A missing recipe input leaves that recipe uncosted.

The Sources & Integration window lists these native sources and the custom aliases already connected to them. Opening it does not create aliases or replace formulas.

## Prospecting: estimate first, account afterward

Shredder's ranking estimates net raw-gem proceeds per five ores from expected quantities and loaded gem minimum buyouts, less a 5% AH fee. It compares that income with owned or planning cost and shows a separate current-buyout scenario. Byproducts and failed deposits are excluded from this ranking.

Actual prospecting accounting is a separate process. UBK records five-ore input costs and actual delivered outputs. Outputs remain pending for the current login session. After reload, complete records are pooled by session and ore type; known ore expense is distributed across the actual outputs.

When all output references are available, allocation uses quantity multiplied by each output's captured reference value. If any reference is missing, the whole pool uses a labeled quantity fallback. Mixing gold weights for some outputs with unit counts for others would distort the allocation, so UBK does not do that.

The allocation preserves the total expense. It does not cap basis at a market quote or erase an unlucky session's loss. A cheaper gem generally receives less cost under relative-value allocation, but a loss-making prospecting session can still produce items whose allocated costs exceed their market values.

Unknown ore costs must be resolved from evidence or an explicit player entry. Incomplete cast, loot, or output-delivery evidence remains pending. An output leaving inventory before settlement requires review; reload is not a substitute for missing evidence.

## Cost and sale value stay separate

Averaging a 55g cost into a 45g expected sale value raises the displayed sale estimate without creating demand. Keep a market-based crafted sale estimate, including a custom `craftsell` if used, separate from the recipe's cost. Compare expected proceeds after fees against that cost.

Historic basis also differs from the cost to buy the materials again, or the proceeds from selling them raw. Market Inspector and Scan Mats help make those alternatives visible. UBK supplies evidence and usable price inputs; your chosen TSM operations determine restocking and posting behavior.
