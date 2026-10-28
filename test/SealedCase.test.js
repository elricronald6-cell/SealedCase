const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const HOUR = 3600;
const E = (n) => ethers.parseEther(String(n));
const SALT = (s) => ethers.id(s);

const envelope = (id, amount, salt, bidder) =>
  ethers.solidityPackedKeccak256(["uint256", "uint256", "bytes32", "address"], [id, amount, salt, bidder]);

describe("SealedCase", function () {
  let sc, owner, seller, ann, ben, cara;

  beforeEach(async () => {
    [owner, seller, ann, ben, cara] = await ethers.getSigners();
    const F = await ethers.getContractFactory("SealedCase");
    sc = await F.deploy();
    await sc.waitForDeployment();
  });

  async function newAuction(reserve = "1", deposit = "0.2") {
    await sc.connect(seller).createAuction("Case 61 — brass desk lamp", E(reserve), E(deposit), 2 * HOUR, 2 * HOUR);
    return (await sc.auctionCount()) - 1n;
  }
  async function commit(id, who, amount, salt, deposit = "0.2") {
    await sc.connect(who).commitBid(id, envelope(id, E(amount), SALT(salt), who.address), { value: E(deposit) });
  }

  it("creates an auction with both windows", async () => {
    const id = await newAuction();
    const a = await sc.getAuction(id);
    expect(a.seller).to.equal(seller.address);
    expect(a.reservePrice).to.equal(E(1));
    expect(a.deposit).to.equal(E("0.2"));
    expect(a.revealEndsAt - a.commitEndsAt).to.equal(2 * HOUR);
    expect(await sc.phaseOf(id)).to.equal(0);
  });

  it("rejects a dust deposit and silly windows", async () => {
    await expect(sc.connect(seller).createAuction("x", E(1), 1, 2 * HOUR, 2 * HOUR)).to.be.revertedWith(
      "deposit too small"
    );
    await expect(sc.connect(seller).createAuction("x", E(1), E(1), 60, 2 * HOUR)).to.be.revertedWith(
      "bad commit window"
    );
    await expect(sc.connect(seller).createAuction("", E(1), E(1), 2 * HOUR, 2 * HOUR)).to.be.revertedWith("bad item");
  });

  it("takes an identical deposit from every bidder and nothing else", async () => {
    const id = await newAuction();
    await expect(
      sc.connect(ann).commitBid(id, envelope(id, E(5), SALT("a"), ann.address), { value: E("0.1") })
    ).to.be.revertedWith("wrong deposit");

    await commit(id, ann, "5", "a");
    expect(await sc.hasCommitted(id, ann.address)).to.equal(true);
    await expect(commit(id, ann, "6", "b")).to.be.revertedWith("already committed");
    await expect(commit(id, seller, "6", "b")).to.be.revertedWith("seller cannot bid");
    expect((await sc.getAuction(id)).bidCount).to.equal(1);
  });

  it("will not let an envelope be opened early or late", async () => {
    const id = await newAuction();
    await commit(id, ann, "5", "a");
    await expect(sc.connect(ann).revealBid(id, E(5), SALT("a"))).to.be.revertedWith("reveal not open");

    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(5), SALT("a"));

    await time.increase(2 * HOUR + 60);
    await expect(sc.connect(ben).revealBid(id, E(5), SALT("a"))).to.be.revertedWith("reveal closed");
  });

  it("refuses a reveal that does not match the envelope", async () => {
    const id = await newAuction();
    await commit(id, ann, "5", "a");
    await time.increase(2 * HOUR + 60);
    await expect(sc.connect(ann).revealBid(id, E(6), SALT("a"))).to.be.revertedWith("does not match");
    await expect(sc.connect(ann).revealBid(id, E(5), SALT("wrong"))).to.be.revertedWith("does not match");
  });

  it("will not let a copied envelope be opened by somebody else", async () => {
    const id = await newAuction();
    const annsEnvelope = envelope(id, E(5), SALT("a"), ann.address);
    await sc.connect(ann).commitBid(id, annsEnvelope, { value: E("0.2") });
    // Ben lifts the hash out of the mempool and commits it as his own.
    await sc.connect(ben).commitBid(id, annsEnvelope, { value: E("0.2") });

    await time.increase(2 * HOUR + 60);
    await expect(sc.connect(ben).revealBid(id, E(5), SALT("a"))).to.be.revertedWith("does not match");
    await sc.connect(ann).revealBid(id, E(5), SALT("a"));
  });

  it("sells at the second price, not the first", async () => {
    const id = await newAuction("1", "0.2");
    await commit(id, ann, "9", "a");
    await commit(id, ben, "6", "b");
    await commit(id, cara, "3", "c");

    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await sc.connect(ben).revealBid(id, E(6), SALT("b"));
    await sc.connect(cara).revealBid(id, E(3), SALT("c"));

    await time.increase(2 * HOUR + 60);
    await sc.connect(cara).settleAuction(id); // permissionless

    const a = await sc.getAuction(id);
    expect(a.highBidder).to.equal(ann.address);
    expect(a.clearingPrice).to.equal(E(6)); // Ben's bid, not Ann's
  });

  it("floors the price at the reserve when only one envelope opens", async () => {
    const id = await newAuction("1", "0.2");
    await commit(id, ann, "9", "a");
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ben).settleAuction(id);
    expect((await sc.getAuction(id)).clearingPrice).to.equal(E(1));
  });

  it("gives revealed losers their deposit back and hands no-shows' deposits to the seller", async () => {
    const id = await newAuction("1", "0.2");
    await commit(id, ann, "9", "a");
    await commit(id, ben, "6", "b");
    await commit(id, cara, "3", "c"); // never reveals

    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await sc.connect(ben).revealBid(id, E(6), SALT("b"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);

    expect(await sc.balanceOf(ben.address)).to.equal(E("0.2"));
    expect(await sc.balanceOf(cara.address)).to.equal(0);
    expect(await sc.balanceOf(seller.address)).to.equal(E("0.2")); // Cara's forfeited deposit
    expect(await sc.balanceOf(ann.address)).to.equal(0); // winner's is held until they pay

    await expect(sc.connect(ben).withdraw()).to.changeEtherBalance(ben, E("0.2"));
    await expect(sc.connect(cara).withdraw()).to.be.revertedWith("nothing to withdraw");
  });

  it("completes the sale with the deposit counting toward the price", async () => {
    const id = await newAuction("1", "0.2");
    await commit(id, ann, "9", "a");
    await commit(id, ben, "6", "b");
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await sc.connect(ben).revealBid(id, E(6), SALT("b"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);

    await expect(sc.connect(ben).payWinningBid(id, { value: E("5.8") })).to.be.revertedWith("not the winner");
    await expect(sc.connect(ann).payWinningBid(id, { value: E(6) })).to.be.revertedWith("wrong amount");

    // Price 6, deposit 0.2 already held, so 5.8 is owed.
    await sc.connect(ann).payWinningBid(id, { value: E("5.8") });

    expect((await sc.getAuction(id)).outcome).to.equal(1); // Sold
    expect(await sc.accumulatedFees()).to.equal(E("0.15")); // 2.5% of 6
    // Both bidders revealed, so no deposit was forfeited — the seller gets the
    // clearing price minus the fee and nothing else.
    expect(await sc.balanceOf(seller.address)).to.equal(E("5.85"));
    await expect(sc.connect(seller).withdraw()).to.changeEtherBalance(seller, E("5.85"));
  });

  it("refunds the winner when the deposit overshoots the clearing price", async () => {
    const id = await newAuction("0.5", "2");
    await commit(id, ann, "9", "a", "2");
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);

    // Price falls to the 0.5 reserve while the deposit was 2.
    await sc.connect(ann).payWinningBid(id, { value: 0 });
    expect(await sc.balanceOf(ann.address)).to.equal(E("1.5"));
  });

  it("hands the winner's deposit to the seller if they never pay", async () => {
    const id = await newAuction("1", "0.2");
    await commit(id, ann, "9", "a");
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);

    await expect(sc.connect(ben).claimDefault(id)).to.be.revertedWith("window still open");
    await time.increase(25 * HOUR);
    await sc.connect(ben).claimDefault(id); // permissionless

    expect((await sc.getAuction(id)).outcome).to.equal(3); // Defaulted
    expect(await sc.balanceOf(seller.address)).to.equal(E("0.2"));
    await expect(sc.connect(ann).payWinningBid(id, { value: E("0.8") })).to.be.revertedWith("closed");
  });

  it("marks an auction unsold when every bid is under the reserve", async () => {
    const id = await newAuction("10", "0.2");
    await commit(id, ann, "3", "a");
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(3), SALT("a"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);

    expect((await sc.getAuction(id)).outcome).to.equal(2); // Unsold
    expect(await sc.balanceOf(ann.address)).to.equal(E("0.2")); // deposit returned
    expect(await sc.balanceOf(seller.address)).to.equal(0);
  });

  it("refuses to settle twice or settle early", async () => {
    const id = await newAuction();
    await commit(id, ann, "5", "a");
    await expect(sc.connect(ann).settleAuction(id)).to.be.revertedWith("reveal still open");
    await time.increase(5 * HOUR);
    await sc.connect(ann).settleAuction(id);
    await expect(sc.connect(ann).settleAuction(id)).to.be.revertedWith("already settled");
  });

  it("pauses new auctions and commits but never a reveal or a withdrawal", async () => {
    const id = await newAuction();
    await commit(id, ann, "5", "a");
    await commit(id, ben, "4", "b");
    await sc.connect(owner).pause();

    await expect(commit(id, cara, "3", "c")).to.be.revertedWithCustomError(sc, "EnforcedPause");
    await expect(
      sc.connect(seller).createAuction("x", E(1), E(1), 2 * HOUR, 2 * HOUR)
    ).to.be.revertedWithCustomError(sc, "EnforcedPause");

    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(5), SALT("a"));
    await sc.connect(ben).revealBid(id, E(4), SALT("b"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);
    await sc.connect(ben).withdraw();
  });

  it("caps the fee, withdraws only fees, and exposes the envelope helper", async () => {
    await expect(sc.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");

    const id = await newAuction("1", "0.2");
    expect(await sc.commitmentFor(id, E(5), SALT("a"), ann.address)).to.equal(
      envelope(id, E(5), SALT("a"), ann.address)
    );

    await commit(id, ann, "9", "a");
    await commit(id, ben, "6", "b");
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).revealBid(id, E(9), SALT("a"));
    await sc.connect(ben).revealBid(id, E(6), SALT("b"));
    await time.increase(2 * HOUR + 60);
    await sc.connect(ann).settleAuction(id);
    await sc.connect(ann).payWinningBid(id, { value: E("5.8") });

    await expect(sc.connect(ann).withdrawFees(ann.address)).to.be.revertedWithCustomError(
      sc,
      "OwnableUnauthorizedAccount"
    );
    await expect(sc.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.15"));
  });
});
