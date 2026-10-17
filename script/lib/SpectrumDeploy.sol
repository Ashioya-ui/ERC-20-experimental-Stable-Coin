// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {SpectralToken} from "../../src/SpectralToken.sol";
import {SpectralStabilizer} from "../../src/SpectralStabilizer.sol";
import {AutonomousTreasury} from "../../src/AutonomousTreasury.sol";
import {SpectralEntropyOracle} from "../../src/SpectralEntropyOracle.sol";
import {SpectralHook} from "../../src/SpectralHook.sol";
import {WrappedSUSD} from "../../src/WrappedSUSD.sol";
import {SpectrumLens} from "../../src/SpectrumLens.sol";
import {TestnetVault} from "./TestnetVault.sol";

/// @title  SpectrumDeploy
/// @notice One deployment procedure shared by the mainnet script, the post-deploy check, the
///         local rehearsal and the fork tests, so what is tested is what is deployed.
library SpectrumDeploy {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Arachnid deterministic deployment proxy (present on Base, Ethereum, anvil).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant MAX_SALT_SEARCH = 4_000_000;

    struct Config {
        uint256 chainId;
        address poolManager;
        address usdc;
        address vault;
        address fallbackVault;
        address admin;
        address guardian;
        bool allowEoaAdmin;
        uint24 poolFee;
        int24 tickSpacing;
        uint256 minObservation;
        uint256 emaAlphaMax;
        uint256 emaTau;
        uint256 staleAfter;
        uint256 bootstrapCap;
        uint256 supplyCap;
        uint256 liquidityBufferBps;
        uint256 seedUsdc; // in USDC base units
        uint256 seedCapitalUsdc; // protocol capital contributed at deployment, USDC base units (Phase 4, B8)
        bool deployTestVaults; // testnets only: deploy two TestnetVaults first (Phase 4, D1)
    }

    struct Deployment {
        AutonomousTreasury treasury;
        SpectralToken token;
        SpectralEntropyOracle oracle;
        SpectralStabilizer stabilizer;
        WrappedSUSD wsusd;
        SpectrumLens lens;
        SpectralHook hook;
        bytes32 hookSalt;
        PoolKey key;
    }

    // ------------------------------------------------------------------------ config

    /// @notice Read config/<chainId>.json (human units are scaled here).
    function loadConfig(string memory path) internal view returns (Config memory c) {
        string memory j = vm.readFile(path);
        c.chainId = vm.parseJsonUint(j, ".chainId");
        c.poolManager = vm.parseJsonAddress(j, ".external.poolManager");
        c.usdc = vm.parseJsonAddress(j, ".external.usdc");
        c.vault = vm.parseJsonAddress(j, ".external.vault");
        c.fallbackVault = vm.parseJsonAddress(j, ".external.fallbackVault");
        c.admin = vm.parseJsonAddress(j, ".roles.admin");
        c.guardian = vm.parseJsonAddress(j, ".roles.guardian");
        c.allowEoaAdmin = vm.parseJsonBool(j, ".roles.allowEoaAdmin");
        // forge-lint: disable-next-line(unsafe-typecast)
        c.poolFee = uint24(vm.parseJsonUint(j, ".params.poolFeePips"));
        // forge-lint: disable-next-line(unsafe-typecast)
        c.tickSpacing = int24(vm.parseJsonInt(j, ".params.tickSpacing"));
        c.minObservation = vm.parseJsonUint(j, ".params.minObservationWsUSD") * 1e18;
        c.emaAlphaMax = vm.parseJsonUint(j, ".params.emaAlphaMaxBps") * 1e14;
        c.emaTau = vm.parseJsonUint(j, ".params.emaTauSeconds");
        c.staleAfter = vm.parseJsonUint(j, ".params.staleAfterSeconds");
        c.bootstrapCap = vm.parseJsonUint(j, ".params.bootstrapCapSUSD") * 1e18;
        c.supplyCap = vm.parseJsonUint(j, ".params.supplyCapSUSD") * 1e18;
        c.liquidityBufferBps = vm.parseJsonUint(j, ".params.liquidityBufferBps");
        c.seedUsdc = vm.parseJsonUint(j, ".params.seedUSDC") * 1e6; // USDC has 6 decimals
        // Optional (default 0): first-loss protocol capital, see audit/parameters.md.
        if (vm.keyExistsJson(j, ".params.seedCapitalUSDC")) {
            c.seedCapitalUsdc = vm.parseJsonUint(j, ".params.seedCapitalUSDC") * 1e6;
        }
        // Optional (default false): Base Sepolia has no USDC lending vault to rehearse with.
        if (vm.keyExistsJson(j, ".external.deployTestVaults")) {
            c.deployTestVaults = vm.parseJsonBool(j, ".external.deployTestVaults");
        }
    }

    /// @notice Testnets only: deploy two plain, clearly labelled ERC-4626 vaults over the
    ///         config's USDC and use them as the primary and fallback vaults. Run inside the
    ///         broadcast, before `preflight` and `deploy`. Refuses Base mainnet.
    function deployTestVaults(Config memory c) internal {
        require(block.chainid != 8453, "deployTestVaults: never on Base mainnet");
        c.vault = address(new TestnetVault(IERC20(c.usdc), "Spectrum TEST vault A (no yield, testnet)", "tvUSDC-A"));
        c.fallbackVault =
            address(new TestnetVault(IERC20(c.usdc), "Spectrum TEST vault B (no yield, testnet)", "tvUSDC-B"));
        console2.log("test vault A             ", c.vault);
        console2.log("test vault B             ", c.fallbackVault);
    }

    // ------------------------------------------------------------------------ preflight

    /// @notice Refuse to deploy into a wrong or unsafe environment. Prints live vault data.
    function preflight(Config memory c, address deployer) internal view {
        require(block.chainid == c.chainId, "preflight: chain id does not match config");
        require(c.poolManager.code.length > 0, "preflight: no code at PoolManager");
        require(c.usdc.code.length > 0, "preflight: no code at USDC");
        require(c.vault.code.length > 0, "preflight: no code at vault");
        require(CREATE2_DEPLOYER.code.length > 0, "preflight: CREATE2 deployer missing");
        require(IERC4626(c.vault).asset() == c.usdc, "preflight: vault asset is not USDC");
        if (c.fallbackVault != address(0)) {
            require(c.fallbackVault.code.length > 0, "preflight: no code at fallback vault");
            require(IERC4626(c.fallbackVault).asset() == c.usdc, "preflight: fallback vault asset is not USDC");
        }
        uint8 dec = IERC20Metadata(c.usdc).decimals();
        require(dec == 6, "preflight: USDC must have 6 decimals");

        require(c.admin != address(0), "preflight: set roles.admin (your Safe) in the config");
        require(c.allowEoaAdmin || c.admin.code.length > 0, "preflight: admin must be a contract (Safe)");
        require(c.admin != deployer, "preflight: admin must not be the deployer key");
        require(c.poolFee <= LPFeeLibrary.MAX_LP_FEE, "preflight: pool fee too high");
        require(
            c.tickSpacing >= TickMath.MIN_TICK_SPACING && c.tickSpacing <= TickMath.MAX_TICK_SPACING,
            "preflight: bad tick spacing"
        );
        require(c.liquidityBufferBps <= 10_000, "preflight: buffer > 100%");
        require(
            c.emaAlphaMax > 0 && c.emaAlphaMax <= 1e18 && c.emaTau > 0 && c.staleAfter > 0,
            "preflight: bad oracle params"
        );
        require(c.supplyCap > 0 && c.bootstrapCap > 0, "preflight: caps must be > 0");

        IERC4626 v = IERC4626(c.vault);
        uint256 oneUsdc = 10 ** dec;
        require(v.maxDeposit(deployer) >= oneUsdc, "preflight: vault refuses deposits (paused, capped, or max*=0)");
        uint256 roundTrip = v.previewRedeem(v.previewDeposit(1_000 * oneUsdc));
        require(roundTrip * 1_000 >= 999 * 1_000 * oneUsdc, "preflight: vault deposit/redeem round trip loses > 0.1%");
        if (c.seedUsdc + c.seedCapitalUsdc > 0) {
            require(
                IERC20(c.usdc).balanceOf(deployer) >= c.seedUsdc + c.seedCapitalUsdc,
                "preflight: deployer lacks USDC for seedUSDC + seedCapitalUSDC"
            );
        }

        console2.log("== preflight ==");
        console2.log("chain id                 ", block.chainid);
        console2.log("deployer                 ", deployer);
        console2.log("deployer ETH (wei)       ", deployer.balance);
        console2.log("admin (Safe)             ", c.admin);
        console2.log("vault                    ", c.vault);
        console2.log("vault totalAssets (USDC) ", v.totalAssets() / oneUsdc);
        console2.log("vault 1 share -> assets  ", v.convertToAssets(oneUsdc));
        console2.log("vault maxDeposit (USDC)  ", v.maxDeposit(deployer) / oneUsdc);
        console2.log("round trip 1,000 USDC -> ", roundTrip);
        console2.log("protocol capital (USDC)  ", c.seedCapitalUsdc / oneUsdc);
    }

    // ------------------------------------------------------------------------ deploy

    /// @notice Deploy everything. Run inside vm.startBroadcast() in scripts.
    /// @dev    Wiring is fixed in constructors, so there is no setter transaction a leaked key
    ///         could race (Phase 4, A3). CREATE addresses are predicted from the deployer's
    ///         nonce and the hook's CREATE2 address from the mined salt; the hook's init code
    ///         names the oracle's predicted address, so there is no cycle. Every prediction is
    ///         checked as soon as the contract exists, and the stabilizer's constructor itself
    ///         refuses a token or treasury that names another stabilizer.
    /// @param  deployer The account whose transactions are sent (msg.sender of every call).
    function deploy(Config memory c, address deployer) internal returns (Deployment memory d) {
        uint256 n = vm.getNonce(deployer);
        address treasuryAt = vm.computeCreateAddress(deployer, n);
        address tokenAt = vm.computeCreateAddress(deployer, n + 1);
        address oracleAt = vm.computeCreateAddress(deployer, n + 2);
        address stabilizerAt = vm.computeCreateAddress(deployer, n + 3);
        address wsusdAt = vm.computeCreateAddress(deployer, n + 4);
        // Hook through the CREATE2 proxy, explicitly, so the mined address is the same in
        // scripts, tests and on-chain.
        bytes memory initCode = hookInitCode(c, oracleAt, wsusdAt);
        (bytes32 salt, address hookAt) = mineHookSalt(keccak256(initCode));

        d.treasury = new AutonomousTreasury(IERC4626(c.vault), c.liquidityBufferBps, stabilizerAt);
        require(address(d.treasury) == treasuryAt, "deploy: treasury address mismatch (deployer nonce moved)");
        d.token = new SpectralToken(stabilizerAt);
        require(address(d.token) == tokenAt, "deploy: token address mismatch (deployer nonce moved)");
        d.oracle = new SpectralEntropyOracle(hookAt, c.minObservation, c.emaAlphaMax, c.emaTau, c.staleAfter);
        require(address(d.oracle) == oracleAt, "deploy: oracle address mismatch (deployer nonce moved)");
        d.stabilizer = new SpectralStabilizer(
            d.token, d.treasury, d.oracle, c.admin, c.guardian, c.bootstrapCap, c.supplyCap, allowedVaults(c)
        );
        require(address(d.stabilizer) == stabilizerAt, "deploy: stabilizer address mismatch (deployer nonce moved)");
        d.wsusd = new WrappedSUSD(IERC20(address(d.token)));
        require(address(d.wsusd) == wsusdAt, "deploy: wsUSD address mismatch (deployer nonce moved)");
        d.lens = new SpectrumLens(d.stabilizer); // read-only views; no address prediction needed

        address hookAddr = create2(salt, initCode);
        require(hookAddr == hookAt, "deploy: hook address mismatch");
        d.hook = SpectralHook(hookAddr);
        d.hookSalt = salt;

        d.key = poolKey(c, address(d.wsusd), hookAddr);
        IPoolManager(c.poolManager).initialize(d.key, parSqrtPriceX96(d.key));

        if (c.seedUsdc > 0) {
            // Dead shares in wsUSD against first-depositor inflation games.
            IERC20(c.usdc).approve(address(d.stabilizer), c.seedUsdc);
            d.stabilizer.mint(c.seedUsdc, deployer, 0);
            d.token.approve(address(d.wsusd), 1e18);
            d.wsusd.deposit(1e18, DEAD);
        }
        if (c.seedCapitalUsdc > 0) {
            // First-loss protocol capital: never distributed, never withdrawable (B8).
            IERC20(c.usdc).approve(address(d.stabilizer), c.seedCapitalUsdc);
            d.stabilizer.contributeCapital(c.seedCapitalUsdc);
        }
    }

    // ------------------------------------------------------------------------ checks

    /// @notice Post-deployment assertions (view only). Reverts with a message on the first
    ///         failure. Safe to run against the live chain at any time.
    function check(Config memory c, Deployment memory d, address deployer) internal view {
        // linkage
        require(d.token.stabilizer() == address(d.stabilizer), "check: token.stabilizer");
        require(d.treasury.stabilizer() == address(d.stabilizer), "check: treasury.stabilizer");
        require(address(d.treasury.asset()) == c.usdc, "check: treasury.asset");
        require(address(d.stabilizer.token()) == address(d.token), "check: stabilizer.token");
        require(address(d.stabilizer.treasury()) == address(d.treasury), "check: stabilizer.treasury");
        require(address(d.stabilizer.oracle()) == address(d.oracle), "check: stabilizer.oracle");
        require(address(d.stabilizer.asset()) == c.usdc, "check: stabilizer.asset");
        require(d.wsusd.asset() == address(d.token), "check: wsUSD.asset");
        require(address(d.lens.stabilizer()) == address(d.stabilizer), "check: lens.stabilizer");
        require(d.oracle.hook() == address(d.hook), "check: oracle.hook");

        // hook: deterministic address = CREATE2(proxy, salt, initCode), with exactly our flags
        require(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "check: hook address flags");
        require(
            hookAddressFor(d.hookSalt, keccak256(hookInitCode(c, address(d.oracle), address(d.wsusd))))
                == address(d.hook),
            "check: hook address does not match CREATE2(salt, initCode)"
        );
        require(address(d.hook.poolManager()) == c.poolManager, "check: hook.poolManager");
        require(address(d.hook.oracle()) == address(d.oracle), "check: hook.oracle");
        require(Currency.unwrap(d.hook.measuredCurrency()) == address(d.wsusd), "check: hook measures wsUSD");
        require(PoolId.unwrap(d.hook.allowedPoolId()) == PoolId.unwrap(d.key.toId()), "check: hook pool id");
        (uint160 sqrtP,,,) = IPoolManager(c.poolManager).getSlot0(d.key.toId());
        require(sqrtP != 0, "check: pool not initialized");
        // Before the first recorded swap the pool must sit at its starting price, inside the
        // hook's band; afterwards trading legitimately moves it, so a deviation is reported.
        if (d.oracle.filled() == 0) {
            require(d.hook.priceWithinBand(sqrtP), "check: pool price is more than 50 bp from wsUSD's redemption value");
        } else if (!d.hook.priceWithinBand(sqrtP)) {
            console2.log("warning: pool price is more than 50 bp from wsUSD's redemption value");
        }

        // roles
        bytes32 adminRole = d.stabilizer.DEFAULT_ADMIN_ROLE();
        bytes32 guardianRole = d.stabilizer.GUARDIAN_ROLE();
        require(d.stabilizer.hasRole(adminRole, c.admin), "check: admin role");
        require(d.stabilizer.hasRole(guardianRole, c.admin), "check: admin guardian role");
        if (c.guardian != address(0)) {
            require(d.stabilizer.hasRole(guardianRole, c.guardian), "check: guardian role");
        }
        if (deployer != c.admin && deployer != c.guardian) {
            require(!d.stabilizer.hasRole(adminRole, deployer), "check: deployer kept admin");
            require(!d.stabilizer.hasRole(guardianRole, deployer), "check: deployer kept guardian");
        }

        // parameters (the vault may differ from the config after a governed migration)
        require(d.treasury.vault().asset() == c.usdc, "check: treasury vault asset");
        require(d.stabilizer.isAllowedVault(c.vault), "check: primary vault not allowlisted");
        if (c.fallbackVault != address(0)) {
            require(d.stabilizer.isAllowedVault(c.fallbackVault), "check: fallback vault not allowlisted");
        }
        require(d.stabilizer.allowedVaults().length <= 2, "check: unexpected vault allowlist");
        require(d.stabilizer.defaultAdminDelay() == d.stabilizer.ADMIN_TRANSFER_DELAY(), "check: admin delay");
        if (address(d.treasury.vault()) != c.vault) console2.log("note: treasury vault was migrated");
        require(d.stabilizer.bootstrapCap() == c.bootstrapCap, "check: bootstrap cap");
        require(d.oracle.minObservation() == c.minObservation, "check: oracle dust");
        require(d.oracle.emaAlphaMax() == c.emaAlphaMax, "check: oracle alpha");
        require(d.oracle.tau() == c.emaTau, "check: oracle tau");
        require(d.oracle.staleAfter() == c.staleAfter, "check: oracle staleness");
        if (d.oracle.filled() < d.oracle.WINDOW()) {
            require(d.oracle.smoothedEntropy() == 0.5e18, "check: entropy not neutral during warm-up");
        }
        require(d.stabilizer.REBASE_STEP_MAX() < d.stabilizer.MINT_FEE_MIN() + d.stabilizer.REDEEM_FEE_MIN(), "check: fees");

        // protocol capital only ever grows; vault rounding may shave a wei of USDC at deposit
        if (c.seedCapitalUsdc > 0) {
            require(d.stabilizer.protocolCapital() + 2e12 >= c.seedCapitalUsdc * 1e12, "check: protocol capital");
        }

        // solvency
        require(d.stabilizer.reserveValue() >= d.token.totalSupply(), "check: reserve below supply");
    }

    /// @notice Print a short state report.
    function report(Deployment memory d) internal view {
        console2.log("== Spectrum state ==");
        console2.log("sUSD supply (wei)        ", d.token.totalSupply());
        console2.log("reserve value (wei)      ", d.stabilizer.reserveValue());
        console2.log("reserve ratio (1e18 = 1) ", d.lens.reserveRatio());
        console2.log("idle USDC                ", d.treasury.idleAssets());
        console2.log("liquid USDC              ", d.treasury.liquidAssets());
        console2.log("liquidity buffer (bps)   ", d.treasury.liquidityBufferBps());
        console2.log("supply cap (wei)         ", d.stabilizer.supplyCap());
        console2.log("smoothed entropy (1e18)  ", d.oracle.smoothedEntropy());
        console2.log("oracle blocks filled     ", d.oracle.filled());
        console2.log("index (1e18)             ", d.token.index());
        console2.log("protocol capital (wei)   ", d.stabilizer.protocolCapital());
        console2.log("distributable now (wei)  ", d.lens.distributable());
    }

    // ------------------------------------------------------------------------ deployment JSON

    function writeDeployment(Config memory c, Deployment memory d, address deployer, string memory path) internal {
        string memory o = "spectrum";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "blockNumber", block.number);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "admin", c.admin);
        vm.serializeAddress(o, "guardian", c.guardian);
        vm.serializeAddress(o, "poolManager", c.poolManager);
        vm.serializeAddress(o, "usdc", c.usdc);
        vm.serializeAddress(o, "vault", c.vault);
        vm.serializeAddress(o, "fallbackVault", c.fallbackVault);
        vm.serializeAddress(o, "treasury", address(d.treasury));
        vm.serializeAddress(o, "sUSD", address(d.token));
        vm.serializeAddress(o, "oracle", address(d.oracle));
        vm.serializeAddress(o, "stabilizer", address(d.stabilizer));
        vm.serializeAddress(o, "wsUSD", address(d.wsusd));
        vm.serializeAddress(o, "lens", address(d.lens));
        vm.serializeAddress(o, "hook", address(d.hook));
        vm.serializeBytes32(o, "hookSalt", d.hookSalt);
        vm.serializeAddress(o, "currency0", Currency.unwrap(d.key.currency0));
        vm.serializeAddress(o, "currency1", Currency.unwrap(d.key.currency1));
        vm.serializeUint(o, "poolFee", d.key.fee);
        vm.serializeInt(o, "tickSpacing", d.key.tickSpacing);
        // constructor arguments, for explorer verification
        vm.serializeUint(o, "liquidityBufferBps", c.liquidityBufferBps);
        vm.serializeUint(o, "minObservation", c.minObservation);
        vm.serializeUint(o, "emaAlphaMax", c.emaAlphaMax);
        vm.serializeUint(o, "emaTau", c.emaTau);
        vm.serializeUint(o, "staleAfter", c.staleAfter);
        vm.serializeUint(o, "bootstrapCap", c.bootstrapCap);
        vm.serializeUint(o, "supplyCap", c.supplyCap);
        vm.serializeUint(o, "seedCapitalUSDC", c.seedCapitalUsdc);
        string memory json = vm.serializeBytes32(o, "poolId", PoolId.unwrap(d.key.toId()));
        vm.writeJson(json, path);
    }

    function loadDeployment(string memory path) internal view returns (Deployment memory d) {
        string memory j = vm.readFile(path);
        d.treasury = AutonomousTreasury(vm.parseJsonAddress(j, ".treasury"));
        d.token = SpectralToken(vm.parseJsonAddress(j, ".sUSD"));
        d.oracle = SpectralEntropyOracle(vm.parseJsonAddress(j, ".oracle"));
        d.stabilizer = SpectralStabilizer(vm.parseJsonAddress(j, ".stabilizer"));
        d.wsusd = WrappedSUSD(vm.parseJsonAddress(j, ".wsUSD"));
        d.lens = SpectrumLens(vm.parseJsonAddress(j, ".lens"));
        d.hook = SpectralHook(vm.parseJsonAddress(j, ".hook"));
        d.hookSalt = vm.parseJsonBytes32(j, ".hookSalt");
        d.key = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(j, ".currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(j, ".currency1")),
            // forge-lint: disable-next-line(unsafe-typecast)
            fee: uint24(vm.parseJsonUint(j, ".poolFee")),
            // forge-lint: disable-next-line(unsafe-typecast)
            tickSpacing: int24(vm.parseJsonInt(j, ".tickSpacing")),
            hooks: IHooks(address(d.hook))
        });
    }

    // ------------------------------------------------------------------------ helpers

    /// @notice The vaults the stabilizer will ever allow: the primary one and, if the config
    ///         names one, the fallback (Phase 4, A5).
    function allowedVaults(Config memory c) internal pure returns (address[] memory list) {
        bool hasFallback = c.fallbackVault != address(0) && c.fallbackVault != c.vault;
        list = new address[](hasFallback ? 2 : 1);
        list[0] = c.vault;
        if (hasFallback) list[1] = c.fallbackVault;
    }

    function hookInitCode(Config memory c, address oracle, address wsusd) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(SpectralHook).creationCode,
            abi.encode(c.poolManager, oracle, Currency.wrap(wsusd), Currency.wrap(c.usdc), c.poolFee, c.tickSpacing)
        );
    }

    function hookAddressFor(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
    }

    /// @notice First salt whose CREATE2 address (via the proxy) carries exactly HOOK_FLAGS.
    function mineHookSalt(bytes32 initCodeHash) internal view returns (bytes32 salt, address hook) {
        for (uint256 i; i < MAX_SALT_SEARCH; ++i) {
            salt = bytes32(i);
            hook = hookAddressFor(salt, initCodeHash);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && hook.code.length == 0) return (salt, hook);
        }
        revert("mineHookSalt: no salt found");
    }

    /// @notice Deploy `initCode` through the CREATE2 proxy; returns the new address.
    function create2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20, "create2: deployment failed");
        deployed = address(bytes20(ret));
    }

    function poolKey(Config memory c, address wsusd, address hook) internal pure returns (PoolKey memory k) {
        (address a0, address a1) = wsusd < c.usdc ? (wsusd, c.usdc) : (c.usdc, wsusd);
        k = PoolKey({
            currency0: Currency.wrap(a0),
            currency1: Currency.wrap(a1),
            fee: c.poolFee,
            tickSpacing: c.tickSpacing,
            hooks: IHooks(hook)
        });
    }

    /// @notice sqrtPriceX96 for 1 wsUSD = 1 USDC given the token order and decimals.
    function parSqrtPriceX96(PoolKey memory k) internal view returns (uint160) {
        uint8 d0 = IERC20Metadata(Currency.unwrap(k.currency0)).decimals();
        uint8 d1 = IERC20Metadata(Currency.unwrap(k.currency1)).decimals();
        // price = 10^(d1 - d0) raw units of token1 per raw unit of token0
        if (d1 >= d0) {
            uint256 up = 10 ** ((d1 - d0) / 2);
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint160((uint256(1) << 96) * up);
        }
        uint256 down = 10 ** ((d0 - d1) / 2);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160((uint256(1) << 96) / down);
    }
}
