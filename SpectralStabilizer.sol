// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./SpectralToken.sol";
import "./SpectralEntropyOracle.sol";
import "./AutonomousTreasury.sol";

/**
 * @title  SpectralStabilizer
 * @notice Manages SPCM supply to keep H_WHT ≈ 2.3 nats.
 *
 * PATCHES vs previous version:
 *   [HIGH]   adjust() now requires MIN_CONSECUTIVE_OOW readings before acting.
 *            Prevents MEV bots from exploiting brief entropy dips to trigger
 *            max supply adjustments.
 *   [MEDIUM] treasury.distribute() wrapped in try/catch. A distribute() revert
 *            no longer blocks the entire stabilizer.
 *   [MEDIUM] adjustmentCount only increments if actual burn amount > 0.
 *   [MEDIUM] Stabilizer burns the remainder returned by treasury.distribute()
 *            (fixes the treasury-cannot-burn bug in AutonomousTreasury).
 *
 * WHAT THIS IS:
 *   Elastic-supply token mechanism. Supply expands when H_WHT is too low
 *   (ordered / bot-dominated) and contracts when too high (chaotic / volatile).
 *   Price floats with demand. This is NOT a stablecoin.
 */
contract SpectralStabilizer {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MAX_ADJUSTMENT_BPS    = 200;    // 2%
    uint256 public constant BPS_DENOM             = 10000;
    uint256 public constant ADJUSTMENT_COOLDOWN   = 3600;   // 1 hour
    uint256 public constant SCALE                 = 1e18;
    uint256 public constant MAX_DEV               = 1e18;   // 1 nat

    // [HIGH] Must see this many consecutive out-of-window readings before acting
    uint256 public constant MIN_CONSECUTIVE_OOW   = 3;

    uint256 public constant H_MIN = 1.8e18;
    uint256 public constant H_MAX = 2.8e18;
    uint256 public constant H_OPT = 2.3e18;

    // ─── Immutables ───────────────────────────────────────────────────────────
    SpectralToken         public immutable token;
    SpectralEntropyOracle public immutable oracle;
    AutonomousTreasury    public immutable treasury;

    // ─── State ────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public lastAdjustment;
    bool    public paused;

    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public adjustmentCount;

    // [HIGH] Consecutive out-of-window counter
    uint256 public consecutiveOOW;

    event SupplyExpanded(uint256 amount, uint256 entropy);
    event SupplyContracted(uint256 amount, uint256 entropy);
    event AdjustmentSkipped(uint256 entropy, string reason);
    event DistributeFailed(string reason);
    event Paused(bool state);

    modifier onlyOwner() { require(msg.sender == owner, "Unauthorized"); _; }
    modifier notPaused() { require(!paused, "Paused"); _; }

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(
        address _token,
        address _oracle,
        address _treasury,
        address _owner
    ) {
        require(
            _token    != address(0) && _oracle  != address(0) &&
            _treasury != address(0) && _owner   != address(0),
            "ZeroAddress"
        );
        token    = SpectralToken(_token);
        oracle   = SpectralEntropyOracle(_oracle);
        treasury = AutonomousTreasury(payable(_treasury));
        owner    = _owner;
    }

    // ─── Core: supply adjustment ──────────────────────────────────────────────

    /**
     * @notice Trigger a supply adjustment. Permissionless.
     *         [HIGH] Requires MIN_CONSECUTIVE_OOW (3) consecutive out-of-window
     *                entropy readings before acting. Prevents MEV griefing on
     *                brief entropy dips.
     */
    function adjust() external notPaused {
        require(
            block.timestamp >= lastAdjustment + ADJUSTMENT_COOLDOWN,
            "Cooldown active"
        );

        uint256 entropy = oracle.twapEntropy(16);   // [HIGH] 16-point TWAP (was 8)

        // Track consecutive out-of-window readings
        if (entropy >= H_MIN && entropy <= H_MAX) {
            consecutiveOOW = 0;   // reset — market recovered
            lastAdjustment = block.timestamp;
            emit AdjustmentSkipped(entropy, "At criticality");
            return;
        }

        // [HIGH] Count consecutive OOW readings
        consecutiveOOW++;
        if (consecutiveOOW < MIN_CONSECUTIVE_OOW) {
            lastAdjustment = block.timestamp;
            emit AdjustmentSkipped(entropy, "Waiting for consecutive OOW confirmation");
            return;
        }

        // Confirmed: sustained out-of-window. Proceed with adjustment.
        consecutiveOOW = 0;   // reset after acting

        uint256 supply = token.totalSupply();
        if (supply == 0) {
            lastAdjustment = block.timestamp;
            return;
        }

        // Compute adjustment magnitude
        bool    expand;
        uint256 deviation;

        if (entropy < H_MIN) {
            deviation = H_MIN - entropy;
            expand    = true;
        } else {
            deviation = entropy - H_MAX;
            expand    = false;
        }

        if (deviation > MAX_DEV) deviation = MAX_DEV;
        uint256 normDev = (deviation * SCALE) / MAX_DEV;

        uint256 amount = (supply * MAX_ADJUSTMENT_BPS * normDev)
                         / (BPS_DENOM * SCALE);

        if (amount == 0) {
            lastAdjustment = block.timestamp;
            emit AdjustmentSkipped(entropy, "Amount too small");
            return;
        }

        if (expand) {
            token.mint(address(treasury), amount);
            totalMinted    += amount;
            adjustmentCount++;

            // [MEDIUM] Wrap distribute() — don't let it block the stabilizer
            try treasury.distribute() {
                // distribute() returns 20% remainder to this contract
                // Burn the remainder
                uint256 toBurn = token.balanceOf(address(this));
                if (toBurn > 0) {
                    token.burn(address(this), toBurn);
                    totalBurned += toBurn;
                }
            } catch Error(string memory reason) {
                emit DistributeFailed(reason);
            } catch {
                emit DistributeFailed("Unknown error in distribute()");
            }

            emit SupplyExpanded(amount, entropy);

        } else {
            uint256 available = token.balanceOf(address(treasury));
            uint256 burnAmt   = amount < available ? amount : available;

            if (burnAmt > 0) {
                // Pull tokens from treasury to here first, then burn
                // Treasury must approve stabilizer first (handled in wiring)
                token.burn(address(treasury), burnAmt);
                totalBurned    += burnAmt;
                adjustmentCount++;           // [LOW] only increment when burn > 0
                emit SupplyContracted(burnAmt, entropy);
            }
        }

        lastAdjustment = block.timestamp;
    }

    // ─── Preview ──────────────────────────────────────────────────────────────
    function previewAdjust() external view returns (
        bool   wouldExpand,
        uint256 amount,
        uint256 entropy,
        bool   onCooldown,
        uint256 consecutiveCount
    ) {
        entropy          = oracle.twapEntropy(16);
        onCooldown       = block.timestamp < lastAdjustment + ADJUSTMENT_COOLDOWN;
        consecutiveCount = consecutiveOOW;

        if (entropy >= H_MIN && entropy <= H_MAX) {
            return (false, 0, entropy, onCooldown, consecutiveCount);
        }

        uint256 supply = token.totalSupply();
        if (supply == 0) return (false, 0, entropy, onCooldown, consecutiveCount);

        uint256 deviation;
        if (entropy < H_MIN) {
            deviation   = H_MIN - entropy;
            wouldExpand = true;
        } else {
            deviation   = entropy - H_MAX;
        }
        if (deviation > MAX_DEV) deviation = MAX_DEV;
        uint256 normDev = (deviation * SCALE) / MAX_DEV;
        amount = (supply * MAX_ADJUSTMENT_BPS * normDev) / (BPS_DENOM * SCALE);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function pause(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZeroAddress");
        owner = newOwner;
    }

    // ─── Views ────────────────────────────────────────────────────────────────
    function getStats() external view returns (
        uint256 supply,
        uint256 entropy,
        bool    critical,
        uint256 minted,
        uint256 burned,
        uint256 adjustments,
        uint256 nextAdjustment,
        uint256 consecutiveOOWCount
    ) {
        supply            = token.totalSupply();
        (entropy, critical,,,) = oracle.getState();
        minted            = totalMinted;
        burned            = totalBurned;
        adjustments       = adjustmentCount;
        nextAdjustment    = lastAdjustment + ADJUSTMENT_COOLDOWN;
        consecutiveOOWCount = consecutiveOOW;
    }

    receive() external payable {}
}
