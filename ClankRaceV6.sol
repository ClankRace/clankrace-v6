// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ClankRaceV6 — fixed-stake, two-tier races with a rolling jackpot.
///
/// V6 fixes a critical RH Chain issue: the EVM block.number counter advances at
/// only ~0.075 blocks/sec (NOT 10/sec), so a block-number-based betting window of
/// 300 blocks took ~67 minutes instead of 30 seconds. V6 uses block.timestamp
/// (wall-clock seconds, advances at exactly 1 sec/sec) for ALL deadlines, so a
/// 30-second window is always 30 seconds regardless of block production rate.
///
/// Two tiers (0.004 ETH / 0.04 ETH) are fully separate pools. Each wallet may bet
/// ONCE per tier per round. A round is PENDING (closeTime == 0) once the first
/// bettor bets; it only STARTS (closeTime set, countdown begins) when a SECOND
/// distinct wallet joins. A lone bettor who never gets an opponent can refund.
/// When nobody backs the on-chain winner, the round pot rolls into that tier's
/// rolling jackpot and carries to the next round.
contract ClankRaceV6 {
    // ---- roles ----
    address public owner;
    address public deployerTreasury; // recipient of the 5% house cut

    // ---- config ----
    uint32 public bettingWindowSeconds = 30; // wall-clock seconds the betting window stays open (owner-settable)

    uint8 constant ENTRANTS = 8;
    uint16 constant CLANK_SUPPLY = 100;
    uint96 constant CUT_BPS = 500; // 5% house cut of each bet

    // tiers: 0 = $10 (~0.004 ETH), 1 = $100 (~0.04 ETH)
    uint8 constant TIERS = 2;
    uint96[TIERS] public stakeOf; // fixed stake per tier (public array -> stakeOf(uint256) getter)

    // ---- rounds (all keyed by tier + roundId) ----
    // A round is PENDING (closeTime == 0) once the first bettor bets. It only
    // STARTS (closeTime set, countdown begins) when a SECOND distinct wallet
    // joins. A lone bettor who never gets an opponent can refund their stake.
    struct Round {
        uint64 closeTime;      // 0 while pending (only 1 bettor); wall-clock sec when 2nd joins sets closeTime = block.timestamp + window
        uint64 startBlock;     // block.number when 2nd bettor joined (used for entropy fallback)
        uint16 bettorCount;    // # of distinct wallets that bet this round
        uint96 pot;            // 95% of every bet on this round
        uint96 payoutPool;     // pot + jackpot, snapshotted at resolve (claimants share this)
        uint96 cut;            // house cut escrowed here while PENDING; released to deployerPending only when the round starts
        uint8  winnerIdx;
        bool   resolved;
        bool   voided;
        bool   rolled;         // true if nobody backed the winner -> pot rolled to jackpot
    }
    uint256[TIERS] public nextRoundId; // per-tier round counter (starts at 1; 0 = "none yet")
    mapping(uint8 => mapping(uint256 => Round)) public rounds;
    mapping(uint8 => mapping(uint256 => uint8)) public entrantCount;
    mapping(uint8 => mapping(uint256 => mapping(uint8 => uint16))) public entrantAt;   // tier -> round -> slot -> clankId
    mapping(uint8 => mapping(uint256 => mapping(uint8 => uint96))) public entrantPot;  // tier -> round -> slot -> total bet
    mapping(uint8 => mapping(uint256 => mapping(address => mapping(uint8 => uint96)))) public userBet; // tier -> round -> better -> slot -> bet
    mapping(uint8 => mapping(uint256 => mapping(address => bool))) public claimedRound;
    mapping(uint8 => mapping(uint256 => mapping(address => bool))) public hasBet;     // one bet per wallet per tier/round

    uint96[TIERS] public jackpot;      // rolling carryover per tier
    uint96 public deployerPending;     // 5% house cut accumulates here

    // reentrancy guard
    uint256 private _locked = 1;

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier nonReentrant() { require(_locked == 1, "reentrant"); _locked = 2; _; _locked = 1; }

    event Bet(uint8 indexed tier, uint256 indexed roundId, uint8 indexed entrantIdx, address better, uint96 amount);
    event Claimed(uint8 indexed tier, uint256 indexed roundId, address user, uint96 amount, bool refund);
    event Refunded(uint8 indexed tier, uint256 indexed roundId, address user, uint96 amount);
    event RoundCreated(uint8 indexed tier, uint256 indexed roundId, uint64 closeTime, uint16[] entrants);
    event Resolved(uint8 indexed tier, uint256 indexed roundId, uint8 winnerIdx, uint16 winnerClank, bool voided, bool rolled);
    event DeployerClaimed(address to, uint96 amount);
    event JackpotSeeded(uint8 indexed tier, uint96 amount);

    constructor(address _treasury) {
        owner = msg.sender;
        deployerTreasury = _treasury;
        stakeOf[0] = 0.004 ether; // ~$10
        stakeOf[1] = 0.04 ether;  // ~$100
        nextRoundId[0] = 1;
        nextRoundId[1] = 1;
    }

    // ---- admin ----
    function setTreasury(address t) external onlyOwner { deployerTreasury = t; }
    function setBettingWindowSeconds(uint32 s) external onlyOwner { require(s >= 5, "too short"); bettingWindowSeconds = s; }
    // NOTE: stakes are intentionally NOT admin-settable. Sirak specified fixed
    // 0.004 ETH / 0.04 ETH tiers; a mutable stake would break the "2nd bettor must
    // match the 1st bettor's stake" guarantee and let refund use the wrong amount.
    function transferOwnership(address o) external onlyOwner { owner = o; }

    /// @notice Owner seeds a tier's jackpot so the very first rounds have upside.
    function seedJackpot(uint8 tier) external payable onlyOwner {
        require(tier < TIERS, "bad tier");
        require(msg.value > 0, "nothing");
        jackpot[tier] += uint96(msg.value);
        emit JackpotSeeded(tier, uint96(msg.value));
    }

    // ---- round creation ----
    function _pickEntrants(uint8 tier) internal view returns (uint16[] memory) {
        uint16[] memory e = new uint16[](ENTRANTS);
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), nextRoundId[tier], block.timestamp, tier));
        uint256 used = 0;
        uint8 count = 0;
        while (count < ENTRANTS) {
            seed = keccak256(abi.encodePacked(seed));
            uint16 id = uint16((uint256(seed) % CLANK_SUPPLY) + 1); // 1..100
            if ((used >> id) & 1 == 0) {
                e[count] = id;
                used |= (uint256(1) << id);
                count++;
            }
        }
        return e;
    }

    function _createRound(uint8 tier) internal returns (uint256 rid) {
        // auto-resolve the previous round if its window has closed (by timestamp)
        if (nextRoundId[tier] > 1) {
            uint256 prev = nextRoundId[tier] - 1;
            if (rounds[tier][prev].closeTime != 0 && !rounds[tier][prev].resolved && block.timestamp >= rounds[tier][prev].closeTime) {
                _resolve(tier, prev);
            }
        }
        uint16[] memory e = _pickEntrants(tier);
        rid = nextRoundId[tier]++;
        // Fresh round starts PENDING (closeTime == 0). The countdown only begins
        // when a second distinct wallet bets (see bet()).
        entrantCount[tier][rid] = ENTRANTS;
        for (uint8 i = 0; i < ENTRANTS; i++) {
            entrantAt[tier][rid][i] = e[i];
        }
        emit RoundCreated(tier, rid, 0, e);
    }

    // ---- betting: fixed stake, one bet per wallet per tier/round, needs 2 to start ----
    function bet(uint8 tier, uint8 i) external payable {
        require(tier < TIERS, "bad tier");
        require(msg.value == stakeOf[tier], "wrong stake");
        uint256 r = nextRoundId[tier] - 1; // 0 == "no round yet"
        // 1) lazily resolve the current round if its window has closed (pending rounds never close)
        if (rounds[tier][r].closeTime != 0 && !rounds[tier][r].resolved && block.timestamp >= rounds[tier][r].closeTime) {
            _resolve(tier, r);
        }
        // 2) if the current round is resolved/voided (or never existed), open a fresh PENDING one
        if (rounds[tier][r].resolved || rounds[tier][r].voided || rounds[tier][r].closeTime == 0 && rounds[tier][r].bettorCount == 0) {
            r = _createRound(tier);
        }
        Round storage rd = rounds[tier][r];
        require(!rd.resolved && !rd.voided, "round closed");
        // betting is allowed while pending (1 bettor) OR during the open window (after 2nd joined)
        require(rd.closeTime == 0 || block.timestamp < rd.closeTime, "betting closed");
        require(i < entrantCount[tier][r], "bad entrant");
        require(!hasBet[tier][r][msg.sender], "already bet this round");

        hasBet[tier][r][msg.sender] = true;
        rd.bettorCount += 1;
        // 5% house cut, 95% to the round pot
        uint256 cut = uint256(msg.value) * uint256(CUT_BPS) / 10000;
        uint256 toPot = uint256(msg.value) - cut;
        rd.pot += uint96(toPot);
        entrantPot[tier][r][i] += uint96(toPot);
        userBet[tier][r][msg.sender][i] += uint96(toPot);
        // The house cut is NOT withdrawable until the round actually starts (2nd
        // bettor joins). While PENDING it is escrowed in rd.cut so the owner can't
        // drain it and then block a solo refund. The 2nd bettor releases it.
        if (rd.bettorCount == 2) {
            deployerPending += rd.cut;          // release the pending cut from bet #1
            rd.cut = 0;
            deployerPending += uint96(cut);    // this bet's cut
            rd.closeTime = uint64(block.timestamp + bettingWindowSeconds); // wall-clock deadline
            rd.startBlock = uint64(block.number); // recorded for entropy fallback
        } else if (rd.bettorCount > 2) {
            deployerPending += uint96(cut);     // round already started -> immediately withdrawable
        } else {
            rd.cut += uint96(cut);              // still pending (1st bettor) -> escrow with the round
        }
        emit Bet(tier, r, i, msg.sender, uint96(toPot));
    }

    /// @notice A lone bettor (no opponent joined yet) can take their stake back anytime.
    /// The house cut was escrowed with the round (never withdrawable), so there is
    /// nothing to reverse — the full stake is still in the contract. Disabled once a
    /// 2nd wallet joins (round started) or after the round is already voided.
    function refund(uint8 tier, uint256 r) external nonReentrant {
        require(tier < TIERS, "bad tier");
        Round storage rd = rounds[tier][r];
        require(rd.closeTime == 0 && !rd.voided, "race already started");
        require(rd.bettorCount == 1, "not solo");
        require(hasBet[tier][r][msg.sender], "not a bettor");
        rd.voided = true;
        uint96 stake = stakeOf[tier];
        rd.pot = 0;
        rd.cut = 0; // escrowed cut was never released to deployerPending; just zero it
        (bool ok, ) = msg.sender.call{value: stake}("");
        require(ok, "refund failed");
        emit Refunded(tier, r, msg.sender, stake);
    }

    // ---- resolution ----
    function resolve(uint8 tier, uint256 r) external {
        require(tier < TIERS, "bad tier");
        require(rounds[tier][r].closeTime != 0, "no round");
        require(!rounds[tier][r].resolved, "resolved");
        require(block.timestamp >= rounds[tier][r].closeTime, "not closed");
        _resolve(tier, r);
    }

    function _resolve(uint8 tier, uint256 r) internal {
        Round storage rd = rounds[tier][r];
        uint8 cnt = entrantCount[tier][r];
        require(cnt > 0, "no entrants");
        require(rd.closeTime != 0, "round pending"); // can't resolve a pending (1-bettor) round
        // Entropy: prefer the previous block's hash (always available within 256
        // blocks), then the start block, then a deterministic packed fallback.
        // block.timestamp is used for the deadline, so we cannot rely on a specific
        // "closing block"; this chain stays robust even if a hash is unavailable.
        bytes32 bh = blockhash(block.number - 1);
        if (bh == bytes32(0)) bh = blockhash(rd.startBlock);
        if (bh == bytes32(0)) bh = keccak256(abi.encodePacked(rd.startBlock, rd.closeTime, r, tier, address(this)));
        uint8 w = uint8(uint256(bh) % cnt);
        rd.winnerIdx = w;
        rd.resolved = true;
        uint16 winClank = entrantAt[tier][r][w];
        if (entrantPot[tier][r][w] == 0) {
            // nobody backed the on-chain winner -> roll the whole pot into the jackpot
            rd.rolled = true;
            jackpot[tier] += rd.pot;
        } else {
            // snapshot pot + carried jackpot into payoutPool; reset the jackpot so the
            // NEXT round starts fresh. Both claimants then read this snapshot (not live
            // jackpot), so neither can shortchange the other.
            rd.payoutPool = uint96(uint256(rd.pot) + uint256(jackpot[tier]));
            jackpot[tier] = 0;
        }
        emit Resolved(tier, r, w, winClank, false, rd.rolled);
    }

    // ---- claim: proportional share of the snapshotted payoutPool ----
    function claim(uint8 tier, uint256 r) external nonReentrant {
        require(tier < TIERS, "bad tier");
        if (!rounds[tier][r].resolved && rounds[tier][r].closeTime != 0 && block.timestamp >= rounds[tier][r].closeTime) {
            _resolve(tier, r);
        }
        require(rounds[tier][r].resolved && !rounds[tier][r].voided, "not resolved");
        require(!claimedRound[tier][r][msg.sender], "already claimed");
        claimedRound[tier][r][msg.sender] = true; // set BEFORE the call (reentrancy safe)
        uint8 w = rounds[tier][r].winnerIdx;
        uint96 myBet = userBet[tier][r][msg.sender][w];
        if (myBet == 0 || entrantPot[tier][r][w] == 0 || rounds[tier][r].rolled) {
            // backed a loser, or the round rolled (nobody backed the winner -> pot to jackpot)
            emit Claimed(tier, r, msg.sender, 0, false);
            return;
        }
        // proportional share of pot + snapshotted jackpot
        uint96 payout = uint96(uint256(myBet) * uint256(rounds[tier][r].payoutPool) / uint256(entrantPot[tier][r][w]));
        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "pay failed");
        emit Claimed(tier, r, msg.sender, payout, false);
    }

    function claimDeployer() external onlyOwner {
        uint96 amt = deployerPending;
        require(amt > 0, "nothing");
        deployerPending = 0;
        (bool ok, ) = deployerTreasury.call{value: amt}("");
        require(ok, "send failed");
        emit DeployerClaimed(deployerTreasury, amt);
    }

    // ---- view helpers (frontend) ----
    function currentRoundId(uint8 tier) external view returns (uint256) { return nextRoundId[tier] - 1; }
    function entrantBet(uint8 tier, uint256 r, uint8 i) external view returns (uint96) { return entrantPot[tier][r][i]; }
    function roundTotalBet(uint8 tier, uint256 r) external view returns (uint96) { return rounds[tier][r].pot; }
    function jackpotOf(uint8 tier) external view returns (uint96) { return jackpot[tier]; }

    receive() external payable {}
}
