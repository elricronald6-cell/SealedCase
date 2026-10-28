# SealedCase

Sealed-bid auctions on BOT Chain, settled at the second price.

Nobody sees a bid until the reveal window opens. Bidders commit a hash, post an
identical deposit, and reveal afterwards. The highest revealed bid wins but pays
the **second** highest — or the reserve, whichever is larger — so there is
nothing to gain from shading your number.

## Three rules keep the envelope honest

1. **The deposit is identical for every bidder**, so the amount staked leaks
   nothing about the bid inside the envelope.
2. **A commitment is bound to the bidder's address** —
   `keccak256(abi.encodePacked(auctionId, amount, salt, bidder))` — so an
   envelope lifted off the mempool cannot be reused by somebody else.
3. **Commit and fail to reveal and your deposit goes to the seller.** A bidder
   who only opens the envelope when the number suits them pays for the
   privilege.

## The flow

| Call | Who | What it does |
|---|---|---|
| `createAuction(item, reserve, deposit, commitSecs, revealSecs)` | anyone | Two windows, 1h–30d each |
| `commitBid(id, commitment)` | anyone but the seller | Posts the fixed deposit |
| `revealBid(id, amount, salt)` | committed bidders | **Works while paused** |
| `settleAuction(id)` | **anyone** | Fixes the winner and the clearing price, returns revealed losers' deposits, hands no-shows' deposits to the seller |
| `payWinningBid(id)` | the winner | Within 24h. The deposit counts toward the price; an overshoot is refunded |
| `claimDefault(id)` | **anyone** | After the window, a winner who never paid forfeits their deposit to the seller |
| `withdraw()` | anyone owed | Pull-based. **Works while paused** |

`withdrawFees` is bounded by `accumulatedFees` and can never reach a deposit or
a seller's proceeds.

## Build and deploy

```bash
npm install
npx hardhat test          # 16 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **OLED pure black**: a true
`#000` canvas, 1px hairline dividers, high-contrast white type and one neon
green. Laid out as master–detail — a scrolling case rail on the left, the
selected case filling the pane on the right — with the facts set as a key/value
table rather than cards.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.

**One thing to know:** the bid amount and salt are sealed in your browser and
stored in `localStorage` only. Clear your site data before revealing and the bid
is lost — the deposit goes to the seller. The page says so on the detail pane,
and offers manual amount/salt entry as a fallback.
