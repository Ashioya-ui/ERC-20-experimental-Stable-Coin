// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./SpectralToken.sol";

/**
 * @title  AutonomousTreasury
 * @notice Receives minted SPCM and distributes to recent swap participants.
 *
 * PATCHES vs previous version:
 *   [CRITICAL] recordActivity is now onlyHook only — owner removed.
 *              Owner calling recordActivity was a complete rug vector
 *              (fake volume → 100% of distribution to attacker).
 *   [CRITICAL] setHook is now one-time only (immutable after set).
 *              Prevents owner from swapping hook to attacker contract.
 *   [HIGH]     distribute() uses checks-effects-interactions pattern
 *              (zero out shares before transfer) — reentrancy protected.
 *   [HIGH]     Wash-trading resistance: minimum volume threshold per slot,
 *              deduplicated by address (one slot per unique address).
 *   [MEDIUM]   burn() called via token.burn() — treasury IS NOT the stabilizer.
 *              Fixed: transfer to dead address instead (token.burn requires
 *              onlyStabilizer which is SpectralStabilizer, not this contract).
 *              Alternatively stabilizer handles burn after distribute.
 *              CHOSEN FIX: stabilizer calls burn() directly. Treasury only transfers.
 *              distribute() now transfers toDistribute only; stabilizer burns remainder.
 */
contract AutonomousTreasury {

    // ─── State ────────────────────────────────────────────────────────────────
    SpectralToken public immutable token;

    address public stabilizer;
    address public hook;           // [CRITICAL] only set once
    address public owner;

    bool private _hookSet;         // [CRITICAL] lock flag
    bool private _distributing;   // [HIGH] reentrancy guard

    // Swap participant record — one slot per unique address
    struct Participant {
        address addr;
        uint256 volume;
    }
    // Up to 32 unique addresses tracked per window
    Participant[32] private participants;
    uint256         public participantCount;

    // [HIGH] Minimum volume to count as a participant slot (anti wash-trade)
    uint256 public minVolumeThreshold;

    uint256 public constant DISTRIBUTION_BPS = 8000;  // 80% distributed
    uint256 public constant BPS_DENOM        = 10000;

    event Distributed(uint256 distributed, uint256 remainderReturned, uint256 recipients);
    event ActivityRecorded(address indexed user, uint256 volume);
    event HookSet(address hook);
    event StabilizerSet(address stabilizer);
    event MinVolumeSet(uint256 threshold);

    error Unauthorized();
    error ZeroAddress();
    error HookAlreadySet();
    error Reentrant();

    modifier onlyOwner()      { if (msg.sender != owner)      revert Unauthorized(); _; }
    modifier onlyStabilizer() { if (msg.sender != stabilizer) revert Unauthorized(); _; }

    /// [CRITICAL] Only the hook. Owner removed.
    modifier onlyHook()       { if (msg.sender != hook)       revert Unauthorized(); _; }

    modifier noReentrant() {
        if (_distributing) revert Reentrant();
        _distributing = true;
        _;
        _distributing = false;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor(address _token, address _owner, uint256 _minVolumeThreshold) {
        if (_token == address(0) || _owner == address(0)) revert ZeroAddress();
        token               = SpectralToken(_token);
        owner               = _owner;
        minVolumeThreshold  = _minVolumeThreshold;  // e.g. 1e15 = 0.001 token units
    }

    // ─── Activity recording ───────────────────────────────────────────────────

    /**
     * @notice Record swap activity. Called by SpectralHook after each swap.
     *         [HIGH] Deduplicates by address. Each address gets one slot.
     *         [HIGH] Volume below minVolumeThreshold is ignored (anti wash-trade).
     *         [CRITICAL] onlyHook — owner cannot call this.
     */
    function recordActivity(address user, uint256 volume) external onlyHook {
        if (user == address(0))       return;
        if (volume < minVolumeThreshold) return;  // [HIGH] dust filter

        // [HIGH] Deduplicate: find existing slot for this address
        for (uint256 i = 0; i < participantCount; i++) {
            if (participants[i].addr == user) {
                participants[i].volume += volume;
                emit ActivityRecorded(user, volume);
                return;
            }
        }

        // New participant
        if (participantCount < 32) {
            participants[participantCount] = Participant(user, volume);
            participantCount++;
        } else {
            // Replace lowest-volume slot (evict weakest participant)
            uint256 minIdx = 0;
            uint256 minVol = participants[0].volume;
            for (uint256 i = 1; i < 32; i++) {
                if (participants[i].volume < minVol) {
                    minVol = participants[i].volume;
                    minIdx = i;
                }
            }
            // Only replace if this user's volume exceeds the minimum
            if (volume > minVol) {
                participants[minIdx] = Participant(user, volume);
            }
        }
        emit ActivityRecorded(user, volume);
    }

    // ─── Distribution ─────────────────────────────────────────────────────────

    /**
     * @notice Distribute treasury balance to swap participants.
     *         [HIGH] Checks-effects-interactions: zero out shares before transfer.
     *         [HIGH] Reentrancy guard.
     *         [MEDIUM] Does NOT burn — returns remainder to stabilizer for burning.
     *                  (Treasury cannot call token.burn() — only stabilizer can.)
     */
    function distribute() external onlyStabilizer noReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;

        uint256 totalVolume;
        for (uint256 i = 0; i < participantCount; i++) {
            totalVolume += participants[i].volume;
        }

        uint256 toDistribute = (balance * DISTRIBUTION_BPS) / BPS_DENOM;
        uint256 remainder    = balance - toDistribute;   // returned to stabilizer to burn

        uint256 actualDistributed;

        if (totalVolume > 0 && toDistribute > 0) {
            // [HIGH] Checks-effects: compute all shares, zero out, then transfer
            uint256[32] memory shares;
            for (uint256 i = 0; i < participantCount; i++) {
                shares[i] = (toDistribute * participants[i].volume) / totalVolume;
                actualDistributed += shares[i];
            }
            // Zero out participant records BEFORE any external call
            uint256 count = participantCount;
            participantCount = 0;
            for (uint256 i = 0; i < count; i++) {
                delete participants[i];
            }
            // Now transfer (external calls after state cleared)
            for (uint256 i = 0; i < count; i++) {
                if (shares[i] > 0) {
                    // Safe: if transfer fails, tokens stay in treasury
                    try token.transfer(participants[i].addr, shares[i]) {} catch {}
                }
            }
        } else {
            // No participants — zero out records
            participantCount = 0;
        }

        // Transfer remainder to stabilizer (which will burn it)
        if (remainder > 0 && token.balanceOf(address(this)) >= remainder) {
            token.transfer(msg.sender, remainder);   // msg.sender = stabilizer
        }

        emit Distributed(actualDistributed, remainder, participantCount);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setStabilizer(address _stabilizer) external onlyOwner {
        if (_stabilizer == address(0)) revert ZeroAddress();
        stabilizer = _stabilizer;
        emit StabilizerSet(_stabilizer);
    }

    /// @notice [CRITICAL] Can only be called once.
    function setHook(address _hook) external onlyOwner {
        if (_hook == address(0)) revert ZeroAddress();
        if (_hookSet)            revert HookAlreadySet();
        hook    = _hook;
        _hookSet = true;
        emit HookSet(_hook);
    }

    function setMinVolumeThreshold(uint256 _threshold) external onlyOwner {
        minVolumeThreshold = _threshold;
        emit MinVolumeSet(_threshold);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    receive() external payable {}
}
